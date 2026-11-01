# Art

`preview.html` renders the marketplace preview (`/preview.png`, 1600×1000) and
`banner.html` the README banner (`docs/media/banner.png`, 1600×560). The panel
images are omakit lab captures (`node tests/lab/prove.mjs . art art`), cropped
inside the panel's border. The waves use the same `voice()` as `src/Model.js`.

```bash
chromium --headless=new --hide-scrollbars --force-device-scale-factor=1 \
  --window-size=1600,1000 --virtual-time-budget=2000 \
  --screenshot="$PWD/preview.png" "file://$PWD/preview.html"
```
