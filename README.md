# `prnt.sc` get

This command-line program downloads your Lightshot ([`prnt.sc`](https://prnt.scr)) gallery and saves it to disk. It is very slow by default so as to be dead certain not to trigger rate-limiting measures; it's meant to be run over a period of hours or even days. The delays between images can be specified when running the program (default values are naturally subject to tweaking). An interrupted run will be resumed on next execution.

Heavily inspired by [Wipie/LightShotGalleryDownloader-CLI](https://github.com/Wipie/LightShotGalleryDownloader-CLI).

## How to get

Either download a binary from the [Releases](https://github.com/zorael/prntscget/releases) page, or clone the source and build it yourself.

```sh
$ git clone https://github.com/zorael/prntscget.git
```

## How to build

You need a [**D**](https://dlang.org) compiler and the official `dub` package manager. On Windows it comes bundled in the compiler archive, while on Linux it may have to be installed separately. Refer to your repositories.

```sh
$ dub build
```

## How to use

```
usage: prntscget [options] [json file]

-c  --cookie Cookie to download gallery of (see README).
-d     --dir Target image directory.
-s   --start Starting image position.
-n     --num Number of images to download.
-r --retries How many times to retry downloading an image.
     --delay Delay between image downloads, in seconds.
   --timeout Download attempt read timeout, in seconds.
   --dry-run Download nothing, only echo what would be done.
```

### Gallery access cookie

To have the program gain access to your gallery, you need to extract the value of the `__auth` cookie that your browser sets when logging into the page, and pass it to the program.

| Browser |Action|
|---------|---|
|Firefox|1. <kbd>Shift</kbd>+<kbd>F9</kbd><br>2. `Cookies` tab<br>3. Select the cookie provider `https://prntscr.com`<br>4. Copy the value of the `__auth` cookie|
|Chrome|1. <kbd>F12</kbd><br>2. Click on `Application` at the top<br>3. `Cookies` section<br>4. Select the cookie provider `https://prntscr.com`<br>5. Copy the value of the `__auth` cookie|

Pass this value to the program with the `-c` switch.

```sh
$ ./prntscget -c thesecretsixtyfourletterauthcookiestringgoeshere
```

This fetches a list of 10,000 of your images and saves it to a file in the current directory (default `target.json`), then starts downloading the images therein.

Subsequent executions of the program will reuse this file, so you only need to supply the cookie once, or whenever you want to update the list with new images.

A `target.json` fetched for use with [Wipie/LightShotGalleryDownloader-CLI](https://github.com/Wipie/LightShotGalleryDownloader-CLI) can be used directly as-is.

## License

This project is licensed under the **MIT** license - see the [LICENSE](LICENSE) file for details.

## Built with

* [D](https://dlang.org)
* [ikod/dlang-requests](https://github.com/ikod/dlang-requests) ([dub](https://code.dlang.org/packages/requests))

## Acknowledgements

* [Wipie/LightShotGalleryDownloader-CLI](https://github.com/Wipie/LightShotGalleryDownloader-CLI)