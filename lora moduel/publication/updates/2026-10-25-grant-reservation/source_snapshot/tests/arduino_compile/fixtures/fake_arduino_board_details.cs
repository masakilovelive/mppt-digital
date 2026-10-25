using System;

public static class FakeArduinoBoardDetails {
  public static int Main(string[] args) {
    string core = Environment.GetEnvironmentVariable(
        "VC_LORA_FAKE_ARDUINO_CORE_PATH");
    if (String.IsNullOrEmpty(core)) {
      Console.Error.Write("VC_LORA_FAKE_ARDUINO_CORE_PATH is required");
      return 21;
    }
    core = core.Replace("\\", "\\\\");
    Console.Write("{\"version\":\"3.3.11\",\"build_properties\":[" +
        "\"build.core.path=" + core + "\"]}");
    return 0;
  }
}
