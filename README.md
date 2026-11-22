# Tracking effects for DaVinci Resolve

**Tracking Point** is a Fusion effect for the Edit page. It tracks a feature on clip A and uses that motion to place a Media Pool clip or timeline (B) over it.

**Tracking Surface** tracks four corners on clip A and uses a perspective corner pin to fit clip B to the moving surface.

https://github.com/user-attachments/assets/0c493607-7a68-4c53-86b2-6c22bbcc4709

## Install on Windows

Run the installer from this folder.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\InstallTrackingPoint.ps1
```

The installer copies both effects to `%APPDATA%\Blackmagic Design\DaVinci Resolve\Support\Fusion\Templates\Edit\Effects` and the Lua scripts to `%LOCALAPPDATA%\TrackingResolve`. Restart Resolve after installation.

## Use Tracking Point

1. On the Edit page, open **Effects Library → Toolbox → Effects** and drag **Tracking Point** onto clip A.
2. Select A and open **Inspector → Effects → Fusion**. Turn on **Preview A for Tracking** to show the tracking controls.
3. At A’s first frame, place **Pattern Center** over a distinct feature that stays visible throughout the clip. Adjust the pattern and search boxes, then click **Bake tracking**. The bake covers A’s full duration on the timeline.
4. Drop a clip or timeline from the Media Pool onto **Insert Clip (Media Pool)**. Turn on **Enable Insert** and turn off **Preview A for Tracking** to see the composite.
5. Use **Start on A (frames)** and **Duration (frames)** to set where B appears on A. **Source In on B (frames)** selects B’s starting frame. You can change these values after baking. Use **Composite Mode** and **Opacity** to adjust how B blends with A.

A dialog reports the reason if a bake fails. Tracking messages are written to `%LOCALAPPDATA%\TrackingResolve\PointInsert.log`.

## Use Tracking Surface

1. Drag **Tracking Surface** from **Effects Library → Toolbox → Effects** onto clip A. Turn on **Preview A for Tracking** in the effect's Inspector.
2. At A's first frame, place **Top Left**, **Top Right**, **Bottom Right**, and **Bottom Left** over the corresponding corners of the same flat surface. Pick distinct details that stay visible. The cyan outline shows the surface, and the pattern and search sizes apply to all four corners.
3. Click **Bake tracking** to track all four corners across A. If a corner is lost, the effect looks for other visible features inside the surface to recover its motion. A dialog reports a recovered or failed bake. A failed bake preserves the last successful track. Scrub with **Preview A for Tracking** on to see the cyan corner markers move. The full log is at `%LOCALAPPDATA%\TrackingResolve\SurfaceInsert.log`.
4. Drop a Media Pool clip or timeline onto **Insert Clip (Media Pool)**, turn on **Enable Insert**, and turn off **Preview A for Tracking**. The entire selected image maps into the four corners. Use the same timing, composite mode, and opacity controls as Tracking Point.
