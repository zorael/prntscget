/++
    Lightshot `prnt.sc` (and `prntscr.com`) gallery downloader.

    https://app.prntscr.com/en/index.html
 +/
module prntscget;

private:

import std.array : Appender;
import std.getopt : GetoptResult;
import std.json : JSONValue;
import core.time : Duration;

public:


/++
    Embodies the notion of an image to be downloaded.
 +/
struct RemoteImage
{
    /// HTTP URL of the image.
    string url;

    /// Local path to save the remote image to.
    string localPath;

    /// Image index (number in list JSON).
    size_t number;

    /// Constructor.
    this(const string url, const string localPath, const size_t number)
    {
        this.url = url;
        this.localPath = localPath;
        this.number = number;
    }
}


/++
    Aggregate of values supplied at the command-line.
 +/
struct Configuration
{
    /// File to save the JSON list of images to.
    string listFile = "target.json";

    /// How many times to retry downloading a file before proceeding with the next one.
    uint retriesPerFile = 100;

    /// Directory to save images to.
    string targetDirectory = "images";

    /// Reques timeout when downloading an image.
    uint requestTimeoutSeconds = 60;

    /// How many seconds to wait inbetween image downloads.
    uint delayBetweenImagesSeconds = 60;

    /// The number of images to skip when downloading (the starting position).
    uint startingImagePosition;

    /// How many images to download.
    uint numToDownload = uint.max;

    /// Cookie specified at the command line.
    string specifiedCookie;

    /// Whether or not this is a dry run.
    bool dryRun;
}


/++
    Program entry point.

    Merely passes execution to [run], wrapped in a try-catch.

    Params:
        args = Arguments passed at the command line.

    Returns:
        zero on success, non-zero on errors.
 +/
int main(string[] args)
{
    try
    {
        return run(args);
    }
    catch (Exception e)
    {
        import std.stdio : writeln;
        writeln("exception thrown: ", e.msg);
        return 1;
    }
}


/++
    Program main logic.

    Params:
        args = Arguments passed at the command line.

    Returns:
        zero on success, non-zero on errors.
 +/
int run(string[] args)
{
    import std.file : exists, readText;
    import std.json : parseJSON;
    import std.stdio : writefln, writeln;
    import core.time : seconds;

    Configuration config;

    auto results = handleGetopt(args, config);

    if (results.helpWanted)
    {
        import std.getopt : defaultGetoptPrinter;
        import std.path : baseName;

        writefln("usage: %s [options] [json file]", args[0].baseName);
        defaultGetoptPrinter(string.init, results.options);
        return 0;
    }

    if (args.length > 1)
    {
        config.listFile = args[1];
        //args = args[1..$];
    }

    if (config.specifiedCookie.length)
    {
        import std.algorithm.searching : canFind;
        import std.stdio : File;

        writefln(`fetching image list JSON and saving into "%s"...`, config.listFile);
        const listFileContents = getImageList(config.specifiedCookie);

        if (!listFileContents.canFind(`"result":{"success":true,`))
        {
            writeln("failed to fetch image list. incorrect cookie?");
            return 1;
        }

        immutable imageListJSON = parseJSON(cast(string)listFileContents);
        writefln("%d images found.", imageListJSON["result"]["total"].integer);
        File(config.listFile, "w").writeln(imageListJSON.toPrettyString);
    }

    if (!config.listFile.exists)
    {
        writefln(`image list JSON file "%s" does not exist.`, config.listFile);
        return 1;
    }

    if (!ensureImageDirectory(config.targetDirectory))
    {
        writefln(`"%s" is not a directory; remove it and try again.`, config.targetDirectory);
        return 1;
    }

    auto listJSON = config.listFile
        .readText
        .parseJSON;
    immutable numImages = listJSON["result"]["total"].integer;

    if (!numImages)
    {
        writeln("no images to fetch.");
        return 0;
    }

    Appender!(RemoteImage[]) images;
    images.reserve(numImages);
    immutable numExistingImages = enumerateImages(images, listJSON, config, numImages);

    if (!images.data.length)
    {
        writefln("no images to fetch -- all %d are already downloaded.", numImages);
        return 0;
    }

    if (numExistingImages > 0)
    {
        writefln("(skipping %d image(s) already in directory.)", numExistingImages);
    }

    writefln("total images: %s -- this will take a MINIMUM of %s.",
        images.data.length, images.data.length*config.delayBetweenImagesSeconds.seconds);

    downloadAllImages(images, config);

    writeln("done.");
    return 0;
}


/++
    Handles getopt arguments passed to the program.

    Params:
        args = Command-line arguments passed to the program.
        config = [Configuration] struct to set the members of.

    Returns:
        [std.getopt.GetoptResult] as returned by the call to [std.getopt.getopt].
 +/
GetoptResult handleGetopt(ref string[] args, out Configuration config)
{
    import std.getopt : getopt, getoptConfig = config;

    return getopt(args,
        getoptConfig.caseSensitive,
        "c|cookie",
            "Cookie to download gallery of (see README).",
            &config.specifiedCookie,
        "d|dir",
            "Target image directory.",
            &config.targetDirectory,
        "s|start",
            "Starting image position.",
            &config.startingImagePosition,
        "n|num",
            "Number of images to download.",
            &config.numToDownload,
        "r|retries",
            "How many times to retry downloading an image.",
            &config.retriesPerFile,
        "delay",
            "Delay between image downloads, in seconds.",
            &config.delayBetweenImagesSeconds,
        "timeout",
            "Download attempt read timeout, in seconds.",
            &config.requestTimeoutSeconds,
        "dry-run",
            "Download nothing, only echo what would be done.",
            &config.dryRun,
    );
}


/++
    Enumerate images, skipping existing ones.

    Params:
        images = [std.array.Appender] containing references to all images to download.
        listJSON = JSON list of images to download.
        config = The current [Configuration] of all getopt values aggregated.
        numImages = The number of images to download, when specified as a lower
            number than the max by getopt.

    Returns:
        The number of images that should be downloaded.
 +/
uint enumerateImages(ref Appender!(RemoteImage[]) images, const JSONValue listJSON,
    const Configuration config, const size_t numImages)
{
    import std.algorithm.comparison : min;
    import std.range : drop, enumerate, retro, take;

    uint numExistingImages;
    bool needsLinebreak;

    scope(exit)
    {
        import std.stdio : writeln;
        if (needsLinebreak) writeln();
    }

    auto range = listJSON["result"]["screens"]
        .array
        .retro
        .drop(config.startingImagePosition)
        .take(min(config.numToDownload, numImages))
        .enumerate;

    foreach (immutable i, imageJSON; range)
    {
        import std.array : replace, replaceFirst;
        import std.file : exists;
        import std.path : buildPath, extension;

        immutable url = imageJSON["url"].str;
        immutable filename = imageJSON["date"].str
            .replace(" ", "_")
            .replaceFirst(":", "h")
            .replaceFirst(":", "m") ~ url.extension;
        immutable localPath = buildPath(config.targetDirectory, filename);

        if (localPath.exists)
        {
            import std.algorithm.comparison : max;
            import std.file : getSize;
            import std.stdio : File, stdout, write;

            enum maxImageEndingMarkerLength = 12;  // JPEG 2, PNG 12

            immutable localPathSize = getSize(localPath);
            immutable seekPos = max(localPathSize-maxImageEndingMarkerLength, 0);
            auto existingFile = File(localPath, "r");
            ubyte[maxImageEndingMarkerLength] buf;

            if (!needsLinebreak)
            {
                needsLinebreak = true;  // well, below
                write("verifying existing images ");
            }

            scope(exit) stdout.flush();

            existingFile.seek(seekPos);
            auto existingFileEnding = existingFile.rawRead(buf);

            if (hasValidJPEGEnding(existingFileEnding) || hasValidPNGEnding(existingFileEnding))
            {
                write('.');
                ++numExistingImages;
                continue;
            }
            else
            {
                write('!');
            }
        }

        images ~= RemoteImage(url, localPath, i);
    }

    return numExistingImages;
}

/++
    Downloads all images in the passed `images` list.

    Images are saved to the filename specified in each [RemoteImage.localPath].

    Params:
        images = The list of images to download.
        config = The current program [Configuration].
 +/
void downloadAllImages(const Appender!(RemoteImage[]) images, const Configuration config)
{
    import core.time : seconds;

    immutable delayBetweenImages = config.delayBetweenImagesSeconds.seconds;
    immutable requestTimeout = config.requestTimeoutSeconds.seconds;

    imageloop:
    foreach (immutable i, const image; images)
    {
        import std.stdio : stdout, write;

        foreach (immutable retry; 0..config.retriesPerFile)
        {
            import requests : RequestException, TimeoutException;
            import std.stdio : writeln;

            try
            {
                if (!config.dryRun && (i != 0) && ((i != (images.data.length+(-1))) || (i == 1)))
                {
                    import core.thread : Thread;
                    Thread.sleep(delayBetweenImages);
                }

                if (retry == 0)
                {
                    import std.stdio : writef;
                    writef("[%4d] %s --> %s: ", image.number, image.url, image.localPath);
                    stdout.flush();
                }

                immutable success = config.dryRun ||
                    downloadImage(image.url, image.localPath, requestTimeout);

                if (success)
                {
                    writeln("ok");
                    continue imageloop;
                }
                else
                {
                    write('.');
                    stdout.flush();
                }
            }
            catch (TimeoutException e)
            {
                // Retry
                write('.');
                stdout.flush();
            }
            catch (RequestException e)
            {
                // Unexpected network error; retry
                write('.');
                stdout.flush();
            }
            catch (Exception e)
            {
                writeln();
                writeln(e.msg);
            }
        }
    }
}


/++
    Downloads an image from the `prnt.sc` server.

    Params:
        url = HTTP URL to fetch.
        imagePath = Filename to save the downloaded image to.
        requestTimeout = Timeout to use when downloading.

    Returns:
        `true` if a file was successfully downloaded (including passing the
        size check); `false` if not.
 +/
bool downloadImage(const string url, const string imagePath, const Duration requestTimeout)
{
    import requests : Request;
    import std.stdio : File;

    Request req;
    req.timeout = requestTimeout;
    req.keepAlive = false;
    auto res = req.get(url);

    if (res.code != 200) return false;

    if (!hasValidPNGEnding(res.responseBody.data) && !hasValidJPEGEnding(res.responseBody.data))
    {
        // Interrupted download?
        return false;
    }

    File(imagePath, "w").rawWrite(res.responseBody.data);
    return true;
}


/++
    Detects whether a passed array of bytes has a valid JPEG ending.

    Params:
        fileContents = Contents of a (possibly) JPEG file.
 +/
bool hasValidJPEGEnding(const ubyte[] fileContents)
{
    import std.algorithm.searching : endsWith;

    static immutable eoi = [ 0xFF, 0xD9 ];
    return fileContents.endsWith(eoi);
}


/++
    Detects whether a passed array of bytes has a valid PNG ending.

    Params:
        fileContents = Contents of a (possibly) PNG file.
 +/
bool hasValidPNGEnding(const ubyte[] fileContents)
{
    import std.algorithm.searching : endsWith;

    static immutable iend = [ 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4e, 0x44, 0xae, 0x42, 0x60, 0x82 ];
    return fileContents.endsWith(iend);
}


/++
    Ensures the target image directory exists, creating it if it does not and
    returning false if it fails to.

    Params:
        targetDirectory = Target directory to ensure existence of.

    Returns:
        `true` if the directory already exists or if it was succesfully created;
        `false` if it could not be.
 +/
bool ensureImageDirectory(const string targetDirectory)
{
    import std.file : exists, isDir, mkdir;

    if (!targetDirectory.exists)
    {
        mkdir(targetDirectory);
        return true;
    }
    else if (!targetDirectory.isDir)
    {
        return false;
    }

    return true;
}


/++
    Fetches the JSON list of images for a passed cookie from the `prnt.sc` server.

    Params:
        cookie = `__auth` cookie to fetch the gallery of.

    Returns:
        A buffer struct containing the response body of the request.
 +/
auto getImageList(const string cookie)
{
    import requests : Request;
    import core.time : seconds;

    enum url = "https://api.prntscr.com/v1/";
    enum post = `{"jsonrpc":"2.0","method":"get_user_screens","id":1,"params":{"count":10000}}`;
    enum webform = "application/x-www-form-urlencoded";

    immutable headers =
    [
        "authority"       : "api.prntscr.com",
        "pragma"          : "no-cache",
        "cache-control"   : "no-cache",
        "accept"          : "application/json, text/javascript, */*; q=0.01",
        "user-agent"      : "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 " ~
            "(KHTML, like Gecko) Chrome/85.0.4183.102 Safari/537.36",
        "content-type"    : "application/json",
        "origin"          : "https://prntscr.com",
        "sec-fetch-site"  : "same-site",
        "sec-fetch-mode"  : "cors",
        "sec-fetch-dest"  : "empty",
        "referer"         : "https://prntscr.com/gallery.html",
        "accept-language" : "fr-CA,fr;q=0.9,fr-FR;q=0.8,en-US;q=0.7,en;q=0.6,it;q=0.5,ru;q=0.4",
        "cookie"          : "__auth=" ~ cookie,
    ];

    Request req;
    req.timeout = 60.seconds;
    req.keepAlive = false;
    req.addHeaders(headers);
    auto res = req.post(url, post, webform);
    return res.responseBody.data;
}
