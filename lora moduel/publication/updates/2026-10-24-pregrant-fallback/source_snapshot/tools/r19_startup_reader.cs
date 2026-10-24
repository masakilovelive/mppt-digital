// PC-only, read-only startup quarantine. No COM is opened or written here.
// A worker owns Read exclusively from Arm until a successful Stop/Join.
using System;
using System.Diagnostics;
using System.Reflection;
using System.Threading;

namespace VcLora.R19 {
    public interface IStartupReadSource {
        int BytesToRead { get; }
        int Read(byte[] buffer, int offset, int count);
        void Close();
    }

    public sealed class SerialStartupSource : IStartupReadSource {
        readonly Func<int> available;
        readonly Func<byte[], int, int, int> read;
        readonly Action close;
        public SerialStartupSource(object serial) {
            Type type = serial.GetType();
            available = (Func<int>)Delegate.CreateDelegate(typeof(Func<int>), serial,
                type.GetProperty("BytesToRead").GetGetMethod());
            read = (Func<byte[], int, int, int>)Delegate.CreateDelegate(
                typeof(Func<byte[], int, int, int>), serial,
                type.GetMethod("Read", new Type[] { typeof(byte[]), typeof(int), typeof(int) }));
            close = (Action)Delegate.CreateDelegate(typeof(Action), serial, type.GetMethod("Close"));
        }
        public int BytesToRead { get { return available(); } }
        public int Read(byte[] buffer, int offset, int count) { return read(buffer, offset, count); }
        public void Close() { close(); }
    }

    public sealed class StartupBlock {
        public int Offset, Count, RequestedCount;
        public long Batch, BeginTicks, EndTicks;
    }

    public sealed class StartupSnapshot {
        public bool Armed, Stopped;
        public int ByteCount, InitialBytes, FirstReadRequestedCount;
        public long OpenReturnTicks, ArmTicks, FirstReadBeginTicks, FirstReadEndTicks, LastReadBeginTicks, LastReadEndTicks;
        public long Calls, Timeouts, ZeroReads, MaximumServiceGapTicks;
        public string Failure;
        public StartupBlock[] Blocks;
    }

    public sealed class StartupReader {
        readonly IStartupReadSource source;
        readonly Stopwatch clock;
        readonly byte[] raw, buffer = new byte[8192];
        readonly StartupBlock[] blocks;
        readonly ManualResetEvent ready = new ManualResetEvent(false);
        readonly ManualResetEvent armed = new ManualResetEvent(false);
        readonly Thread worker;
        volatile bool stop;
        bool wasArmed;
        int used, blockCount, initialBytes = -1, firstRequested;
        long openReturnTicks = -1, armTicks = -1, firstBegin = -1, firstEnd = -1, lastBegin = -1, lastEnd = -1;
        long calls, timeouts, zeroReads, maxGap;
        string failure = "";

        public StartupReader(IStartupReadSource source, Stopwatch clock, int capacity, int blockCapacity) {
            if (source == null || clock == null || !clock.IsRunning || capacity < 1 || blockCapacity < 1)
                throw new ArgumentException("Invalid startup reader configuration.");
            this.source = source; this.clock = clock;
            raw = new byte[capacity]; blocks = new StartupBlock[blockCapacity];
            // Allocate every record before Open, including JIT/warm-up below.
            for (int i = 0; i < blocks.Length; i++) blocks[i] = new StartupBlock();
            worker = new Thread(Run); worker.IsBackground = true;
            worker.Name = "R19 read-only startup quarantine";
            worker.Start();
        }

        public bool WaitReady(int milliseconds) { return ready.WaitOne(milliseconds); }
        public void Arm() { Arm(clock.ElapsedTicks); }
        public void Arm(long openReturnTicks) {
            if (!ready.WaitOne(0) || wasArmed || stop) throw new InvalidOperationException("Reader not ready to arm.");
            this.openReturnTicks = openReturnTicks;
            armTicks = clock.ElapsedTicks; wasArmed = true; armed.Set();
        }
        // Normal ownership transfer relies on the unchanged SerialPort 20 ms
        // ReadTimeout. False forbids a main-thread Read; cleanup must Close/join.
        public bool Stop(int milliseconds) { stop = true; armed.Set(); return worker.Join(milliseconds); }

        void Run() {
            // Exercise allocation/copy/clock and catch paths before reporting ready.
            var warm = new byte[1]; Buffer.BlockCopy(warm, 0, buffer, 0, 1);
            long unused = clock.ElapsedTicks;
            ready.Set(); armed.WaitOne();
            if (stop) return;
            try {
                initialBytes = source.BytesToRead;
                if (initialBytes < 0) throw new InvalidOperationException("Negative initial byte count.");
                while (!stop) {
                    if (used == raw.Length) { failure = "STARTUP_BYTE_CAPACITY"; break; }
                    if (blockCount == blocks.Length) { failure = "STARTUP_BLOCK_CAPACITY"; break; }
                    int count = Math.Min(buffer.Length, raw.Length - used);
                    long begin = clock.ElapsedTicks;
                    if (lastBegin >= 0) maxGap = Math.Max(maxGap, begin - lastBegin);
                    if (firstBegin < 0) { firstBegin = begin; firstRequested = count; }
                    lastBegin = begin; calls++;
                    int n;
                    try { n = source.Read(buffer, 0, count); }
                    catch (TimeoutException) {
                        timeouts++; lastEnd = clock.ElapsedTicks;
                        if (firstEnd < 0) firstEnd = lastEnd;
                        continue;
                    }
                    lastEnd = clock.ElapsedTicks;
                    if (firstEnd < 0) firstEnd = lastEnd;
                    if (n < 0 || n > count) throw new InvalidOperationException("Invalid read count.");
                    if (n == 0) { zeroReads++; Thread.Sleep(1); continue; }
                    Buffer.BlockCopy(buffer, 0, raw, used, n);
                    StartupBlock block = blocks[blockCount++];
                    block.Offset = used; block.Count = n; block.RequestedCount = count; block.Batch = calls;
                    block.BeginTicks = begin; block.EndTicks = lastEnd; used += n;
                }
            } catch (Exception error) { failure = error.GetType().Name + ": " + error.Message; }
        }

        void RequireStopped() {
            if (worker.IsAlive) throw new InvalidOperationException("Snapshot before reader Stop/Join.");
        }
        public byte[] GetBytes() {
            RequireStopped(); byte[] result = new byte[used];
            Buffer.BlockCopy(raw, 0, result, 0, used); return result;
        }
        public StartupSnapshot GetSnapshot() {
            RequireStopped(); StartupBlock[] result = new StartupBlock[blockCount];
            for (int i = 0; i < result.Length; i++) {
                StartupBlock b = blocks[i];
                result[i] = new StartupBlock { Offset = b.Offset, Count = b.Count, RequestedCount = b.RequestedCount,
                    Batch = b.Batch, BeginTicks = b.BeginTicks, EndTicks = b.EndTicks };
            }
            return new StartupSnapshot { Armed = wasArmed, Stopped = !worker.IsAlive,
                ByteCount = used, InitialBytes = initialBytes, FirstReadRequestedCount = firstRequested,
                OpenReturnTicks = openReturnTicks, ArmTicks = armTicks,
                FirstReadBeginTicks = firstBegin, FirstReadEndTicks = firstEnd, LastReadBeginTicks = lastBegin,
                LastReadEndTicks = lastEnd, Calls = calls, Timeouts = timeouts, ZeroReads = zeroReads,
                MaximumServiceGapTicks = maxGap, Failure = failure, Blocks = result };
        }
    }
}
