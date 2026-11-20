# Third-party notices

## libmtp and libusb

The native MTP bridge is adapted from the local PixelTransfer project. These libraries are dynamically loaded and replaceable; private signing keys are not required to replace/rebuild them.

- libmtp 1.1.23: https://github.com/libmtp/libmtp — license text: `Resources/Libraries.bundle/libmtp-LICENSE.txt`.
- libusb: https://github.com/libusb/libusb — license text: `Resources/Libraries.bundle/libusb-LICENSE.txt`.

Bundled binaries currently target arm64, macOS 27+. Their license texts retain their own terms independently of the application code. The libmtp public header retains its upstream notices.

## Lyrics

Optional lyrics lookup uses LRCLIB: https://lrclib.net. Search results and users' media/lyrics are not included in the repository or installer.

## Visual references and resources

This is an unofficial project inspired by iTunes 9 and Mac OS X Snow Leopard. Apple names, marks and reference graphics remain the property of their respective rightsholders. The resources in `Resources/` are not offered under a blanket code license; their presence does not grant a trademark license or assert ownership by this project. No general license for the original application code has been selected yet.

## Test fixtures

`Tests/Fixtures` contains small artificial metadata/audio fixtures used by the automated test suite. No imported user music library, play history, playlists, lyrics cache or Android inventory is distributed.
