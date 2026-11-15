# Browser QR dependencies

These dependencies run locally in the wallet browser. The app does not load a CDN
or send QR contents to an external service.

Use the pinned lockfile to rebuild the committed browser bundle:

```sh
cd scripts/qr-vendor
npm ci --ignore-scripts
npm run build
```

`@ngraveio/bc-ur` decodes animated UR responses. `jsqr` decodes camera frames and QR
images. The application bounds message size, fragment counts and fountain work
before the UR decoder receives a frame. It also bounds decompression output.
`buffer` and `process` provide browser adapters for the packages' Node interfaces.

The output is `web/vendor/signing-qr.js`. License texts are in
`web/vendor/signing-qr-LICENSES.txt`. Review and update that file if dependencies
change. Run `scripts/test-hardware-browser.cjs` after any dependency update.

Source projects:

- <https://github.com/ngraveio/bc-ur>
- <https://github.com/cozmo/jsQR>
- <https://github.com/feross/buffer>
- <https://github.com/defunctzombie/node-process>

The application uses the [BBQr format](https://github.com/coinkite/BBQr) to display
unsigned PSBTs. This generated bundle contains no wallet credentials or keys.
