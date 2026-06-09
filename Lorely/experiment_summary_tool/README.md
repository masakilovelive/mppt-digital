# Experiment Summary Tool

CSV experiment logs are analyzed with Python, then summarized into Excel, graphs, and reports.

## Folder Layout

```text
experiment_summary_tool/
  config/
    experiment_config.yaml
  logs/
    raw_csv/
      sample_exp001_pv_step.csv
  output/
    graphs/
  scripts/
    analyze_experiment.py
  requirements.txt
```

## Install

```powershell
cd Lorely\experiment_summary_tool
python -m venv .venv
.\.venv\Scripts\Activate.ps1
python -m pip install -r requirements.txt
```

## Run

```powershell
python scripts\analyze_experiment.py
```

If `python` opens the Microsoft Store stub, use `uv` instead:

```powershell
uv run --with pandas --with openpyxl --with matplotlib --with pyyaml --with reportlab python scripts\analyze_experiment.py
```

Outputs:

```text
output/
  summary.xlsx
  report.md
  report.pdf          # generated when reportlab is installed
  graphs/
    *_power.png
    *_temperature.png
    *_command.png
```

## Browser Dashboard

Open `experiment_dashboard.html` in a browser, or run:

```powershell
.\open_experiment_dashboard.ps1
```

Then drag CSV files from `logs/raw_csv` onto the page. The dashboard shows:

```text
PASS / WARN / FAIL
power, temperature, and command graphs
summary metrics
summary CSV export
```

## CSV Columns

The analyzer accepts partial CSVs, but these columns are recommended:

```text
time_ms, mode,
P_pv_sim, V_pv, I_pv,
P_load, V_load, I_load,
P_aux, V_aux, I_aux, E_aux,
u_cmd, theta_thr,
temp_power, temp_load, temp_vesc,
rpm, pitch, roll,
fault_code, comm_state
```

## Excel Sheets

```text
01_Experiment_List
02_Conditions
03_Result_Summary
04_Judgement
05_Graphs
06_Failsafe_History
07_Final_Parameters
08_Notes
```

## Judgement

The final judgement is selected in this order:

```text
FAIL: over-current, over-power, communication loss, or failsafe/fault occurred
WARN: temperature, voltage, communication delay, or target-power quality warning
PASS: stable enough and no warning/failure rule was triggered
```

Thresholds can be edited in `config/experiment_config.yaml`.
