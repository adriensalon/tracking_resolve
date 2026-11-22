# Tracking Point for DaVinci Resolve

**Tracking Point** is a Fusion effect for the Edit page. It tracks a feature on clip A and uses that motion to place a Media Pool clip or timeline (B) over it.

## Install on Windows

Run the installer from this folder.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\InstallTrackingPoint.ps1
```

The installer copies `Tracking Point.setting` to `%APPDATA%\Blackmagic Design\DaVinci Resolve\Support\Fusion\Templates\Edit\Effects` and the Lua scripts to `%LOCALAPPDATA%\TrackingResolve`. Restart Resolve after installation.

## Use Tracking Point

1. On the Edit page, open **Effects Library → Toolbox → Effects** and drag **Tracking Point** onto clip A.
2. Select A and open **Inspector → Effects → Fusion**. Turn on **Preview A for Tracking** to show the tracking controls.
3. At A’s first frame, place **Pattern Center** over a distinct feature that stays visible throughout the clip. Adjust the pattern and search boxes, then click **Bake tracking**. The bake covers A’s full duration on the timeline.
4. Drop a clip or timeline from the Media Pool onto **Insert Clip (Media Pool)**. Turn on **Enable Insert** and turn off **Preview A for Tracking** to see the composite.
5. Use **Start on A (frames)** and **Duration (frames)** to set where B appears on A. **Source In on B (frames)** selects B’s starting frame. You can change these values after baking. Use **Composite Mode** and **Opacity** to adjust how B blends with A.

Tracking messages are written to `%LOCALAPPDATA%\TrackingResolve\PointInsert.log`.
