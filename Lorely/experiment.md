# experiment

This file is the entry point for the experiment analysis assets generated from the conversation.

## Tool

Use `experiment_summary_tool` for CSV-based experiment analysis.

```text
Lorely/experiment_summary_tool/
  experiment_dashboard.html
  open_experiment_dashboard.ps1
  scripts/analyze_experiment.py
  logs/raw_csv/sample_exp001_pv_step.csv
  config/experiment_config.yaml
```

## Browser UI

Open:

```text
Lorely/experiment_summary_tool/experiment_dashboard.html
```

or run:

```powershell
cd Lorely\experiment_summary_tool
.\open_experiment_dashboard.ps1
```

Drag CSV files onto the dashboard to visualize:

```text
PASS / WARN / FAIL
power graph
temperature graph
u_cmd / theta_thr graph
summary metrics
summary CSV export
```

## Python Analysis

```powershell
cd Lorely\experiment_summary_tool
uv run --with pandas --with openpyxl --with matplotlib --with pyyaml --with reportlab python scripts\analyze_experiment.py
```

Outputs are written to:

```text
Lorely/experiment_summary_tool/output/
```
