# *This does currently not work*

I can no longer sign in. My IP may have been banned, or their service is simply down (and has been down for several days?). The newly-added captcha can be worked around by *always* specifying cookies and browser agent, which is a pain.

I have some uncommitted changes that made it work, prior to everything just returning "forbidden". Will update (and potentially push them) when I know more.

# `prnt.sc` get

This command-line program downloads your Lightshot ([`prnt.sc`](https://prnt.scr)) gallery and saves it to disk.

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
usage: prntscget [options]

-c      --cookie Cookie to download gallery of (see README).
-f        --file Filename to save the JSON list of images to.
-d         --dir Target image directory.
-o      --offset Images to skip considering, before checking for existing images.
-s        --skip Images to effectively skip downloading, after applying offset and checking for existing files.
-n         --num Number of images to download.
-r     --retries How many times to retry downloading an image.
-D       --delay Delay between image downloads, in seconds.
-t     --timeout Download attempt read timeout, in seconds.
   --always-keep Whether or not to always keep downloaded files, even if they're not valid images.
       --dry-run Download nothing, only echo what would be done.
```

### Gallery access cookie

To have the program gain access to your gallery, you need to extract the value of the `__auth` cookie that your browser sets when logging into the page, and pass it to the program.

| Browser | Action |
|---------|--------|
|Firefox|1. <kbd>Shift</kbd>+<kbd>F9</kbd><br>2. `Cookies` dropdown menu<br>3. Select the cookie provider `https://prntscr.com`<br>4. Copy the value of the `__auth` cookie|
|Chrome|1. <kbd>F12</kbd><br>2. Click on `Application` at the top<br>3. `Cookies` section<br>4. Select the cookie provider `https://prntscr.com`<br>5. Copy the value of the `__auth` cookie|

Pass this value to the program with the `-c` switch.

```sh
$ ./prntscget -c thesecretsixtyfourletterauthcookiestringgoeshere
```

This fetches a list of 10,000 of your images and saves it to a file in the current directory (default `target.json`), then starts downloading the images listed therein.

Subsequent executions of the program will reuse this file, so you only need to supply the cookie once, or whenever you want to update the list and sync it with your gallery for new images.

If the process was interrupted it will resume downloading where it previously stopped. Failed downloads are detected and will be retried.

> A `target.json` fetched for use with [Wipie/LightShotGalleryDownloader-CLI](https://github.com/Wipie/LightShotGalleryDownloader-CLI) can be used directly as-is.

## If it doesn't work

[File an issue.](https://github.com/zorael/prntscget/issues/new)

## License

This project is licensed under the **MIT** license - see the [LICENSE](LICENSE) file for details.

## Acknowledgements

* [Wipie/LightShotGalleryDownloader-CLI](https://github.com/Wipie/LightShotGalleryDownloader-CLI)
