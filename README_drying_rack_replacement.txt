Quartz DR1713 Replacement Script - Setup Notes
==============================================

Script:
  quartz_batch_drying_rack_replace.ms

What it does
------------
1) Recursively scans ROOT_DIR for source .max files.
2) For each file:
   - Parses finish token from filename (3rd dash token).
   - Loads matching drying-rack material from Drying Racks.mat.
   - Creates backup in mirrored BACKUP_DIR structure.
   - Opens file quietly.
   - Finds DR1713 parent/root node(s).
   - Deletes each old DR1713 hierarchy.
   - Imports Drying_Rack.fbx.
   - Aligns imported rack center to old rack center (and applies old rotation/scale if single imported root).
   - Assigns mapped rack material recursively to imported rack nodes.
   - Saves file and resets Max.
3) Logs success/skipped/failed summary.

Required paths to verify
------------------------
- ROOT_DIR
- BACKUP_DIR
- DRYING_RACK_FBX_PATH
- DRYING_RACK_MATLIB_PATH

Material mapping
----------------
- BI -> Bisque
- BL -> Black
- BR -> Light brown
- CN -> Light Grey #1
- GR -> Dark Grey
- WH -> White_Rubber

Important notes
---------------
- Script targets rack roots named exactly DR1713.
- Backup is created before any file modifications.
- If your FBX imports as multiple top nodes, script aligns imported set by center.
- If your FBX import settings differ per workstation, validate one sample file first.
