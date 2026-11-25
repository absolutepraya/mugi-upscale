# Mugi

Mugi is a local image upscaler for Apple Silicon. This glossary names the parts of its window and the ideas behind updating the app.

## Language

### Main window

**Workspace**:
The white rounded panel that holds the zoom controls, the two preview panes, and the action row.
_Avoid_: Inner window, card, canvas

**Preview pane**:
One of the two image areas in the workspace, such as Original or Upscaled. Each shows a label, the image dimensions, and an Open button.
_Avoid_: Panel, viewer

**Action row**:
The row at the bottom of the workspace that holds Output Size, Upscale or Cancel, and Save, with the progress loader at its left end while an upscale runs.
_Avoid_: Button bar, toolbar

**Control bar**:
The area below the workspace with the model picker, the model bars, the status row, and the system stats gauges.
_Avoid_: Bottom bar, footer

**Status row**:
The line of small text in the control bar showing output size, format, activity, and elapsed time.
_Avoid_: Status bar

**Enlarged preview**:
A separate resizable window that shows one preview pane's image at a larger size. It opens from that pane's Open button.
_Avoid_: Sheet, popup, lightbox

**Glass**:
How see-through the window background is, set by a percentage in Settings. At 100% the window shows the frosted glass in full, and at 0% it is a solid window color.
_Avoid_: Frosted percentage, blur, opacity

### Updates

**Update check**:
A look at the newest published release, made automatically on launch at most once a day or when the user asks in About.
_Avoid_: Auto-update, sync

**Update**:
Replacing the installed app with a newer release. It only starts when the user clicks the Update button, and it never runs during an upscale.
_Avoid_: Auto-update, upgrade
