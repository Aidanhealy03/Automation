Quartz Backburner Batch Render Script - Setup Notes
===================================================

Script:
  quartz_backburner_batch_render.ms

What it does
------------
1) Recursively scans ROOT_DIR for .max source files.
2) For each source file:
   - Loads SAMPLE_SCENE_PATH (lighting + cameras template).
   - Merges the source sink/accessory scene into the sample scene.
   - Prepares 4 camera renders (IPS01..IPS04).
   - For IPS03 only: hides nodes with prefixes CB, DR, COL.
   - Saves a temp .max per camera variant.
   - Submits each camera render to Backburner manager (10.10.0.59)
     through cmdjob + 3dsmaxcmd.
3) Logs per-file and overall summary in Listener.

Naming convention
-----------------
Output job/render names follow:
  KCL_144_IPS#_Quartz-Workstation-Refresh_SKUFINISH

Examples:
  KCL_144_IPS01_Quartz-Workstation-Refresh_QARWS740BIPK2Bisque

Required edits before first run
-------------------------------
Open quartz_backburner_batch_render.ms and verify these globals:

- ROOT_DIR
- SAMPLE_SCENE_PATH
- OUTPUT_DIR
- TEMP_SCENE_DIR
- BACKBURNER_MANAGER_IP         (currently 10.10.0.59)
- CMDJOB_EXE                    (Backburner cmdjob path)
- MAXCMD_EXE                    (3dsmaxcmd path)

Important runtime assumptions
-----------------------------
- Sample scene contains cameras: IPS01, IPS02, IPS03, IPS04.
- Backburner Server/Manager are running and reachable.
- cmdjob.exe and 3dsmaxcmd.exe exist at configured paths.
- 3dsmaxcmd command-line flags may vary slightly by Max version.
  If submission fails, test cmdjob command manually and adjust:
    -camera
    -o
    -frames

Recommended dry run
-------------------
- Test with 1-2 source files first.
- Confirm jobs appear in Backburner Monitor.
- Confirm IPS03 outputs hide CB/DR/COL objects.
- Confirm output names match naming convention expectations.

Notes
-----
- This script submits jobs; rendering executes on Backburner nodes.
- Temp scenes are intentionally preserved in TEMP_SCENE_DIR for audit/debug.
