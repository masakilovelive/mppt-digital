# Eigenvalue and Eigenvector GUI Simulator

This project provides browser-based simulators:

- `eigen_simulation.html`: linear algebra GUI with three tabs:
  - `2D Simulation`: 2x2 matrix mode, eigenvalues/eigenvectors, trajectory plot, and table.
  - `3D Simulation`: 3x3 matrix mode, cubic eigenvalue approximation, projected 3D trajectory, and dominant eigendirection estimate.
  - `Linear Map Notes`: summary of PDF topics (Im(A), Ker(A), invertibility, Ax=b, rank-nullity, dual space, dual basis).
- `multistage_efficiency_simulation.html`: multi-stage power module efficiency simulator with:
  - single-stage vs multi-stage comparison,
  - stage-by-stage power/current/loss breakdown,
  - chart generation for power/current/efficiency/loss/sweep results,
  - boost duty approximation and Vbus sweep,
  - TeX decompile + compiled formula view,
  - JSON export/import for current model + computed results.

## Run Eigen Simulator

1. Open `eigen_simulation.html` from this repository in a browser.
   If you enter the path manually in the address bar, use a `file:///C:/...` URL instead of a raw `C:\...` path.
2. Choose `2D Simulation`, `3D Simulation`, or `Linear Map Notes` tab.
3. Edit matrix `A`, initial vector `x0`, and step count.
4. Set vector `b` and click `Run 2D` or `Run 3D`.

## Run Multi-Stage Efficiency Simulator

1. Open `multistage_efficiency_simulation.html` from this repository in a browser.
   If you enter the path manually in the address bar, use `file:///C:/Users/n5483/Documents/GitHub/mppt-digital/multistage_efficiency_simulation.html` instead of a raw `C:\Users\...\multistage_efficiency_simulation.html` path.
   You can also run `.\open_multistage_efficiency_simulation.ps1` from PowerShell in this folder.
2. Set load (`Vout`, `Iout`), source voltage (`Vin`), and single-stage efficiency.
3. Configure cascaded stage modules (topology, `Vout`, stage efficiency).
4. Click `Run simulation` to compute:
   - total multi-stage efficiency,
   - source current and input power comparison against single-stage,
   - per-stage power/current/loss details,
   - boost `D ~ 1 - eta*Vin/Vbus` sweep table.
5. Use `Simulation State I/O` to export/import JSON snapshots and reload scenarios.

## Notes

- 2D mode computes exact eigenvalues from the quadratic characteristic polynomial.
- 3D mode solves the cubic characteristic polynomial numerically and shows approximate eigenvalues.
- In 3D mode, the dashed orange line is the estimated dominant eigendirection from power iteration.
- Both 2D and 3D modes include linear-system analysis: `rank`, `nullity`, invertibility check, `b in Im(A)` test, and solution-set form `x0 + Ker(A)`.
- The multi-stage simulator uses KaTeX CDN for compiled formula rendering; if unavailable, TeX text is still shown.
