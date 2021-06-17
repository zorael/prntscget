/++
    Lightshot `prnt.sc` (and `prntscr.com`) gallery downloader.

    See_Also: https://app.prntscr.com/en/index.html
 +/
module prntscget.app;

private:

import std.array : Appender;
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
    Aggregate of values supplied at the command line.
 +/
struct Configuration
{
    /// File to save the JSON list of images to.
    string listFile = "target.json";

    /++
     +  How many times to try downloading a file before admitting failure and
     +  proceeding with the next one.
     +/
    uint retriesPerFile = 100;

    /// Directory to save images to.
    string targetDirectory = "images";

    /// Request timeout when downloading an image.
    uint requestTimeoutSeconds = 60;

    /// How many seconds to wait between image downloads.
    double delayBetweenImagesSeconds = 1.0;

    /// The number of images to skip when downloading (e.g. the index starting position).
    uint startingImagePosition;

    /// How many images to download, ignoring duplicates.
    uint numToDownload = uint.max;

    /// `__auth` cookie string specified at the command line.
    string cookie;

    /// Whether or not this is a dry run.
    bool dryRun;
}


/++
    Shell return values.
 +/
enum ShellReturn : int
{
    success           = 0,  /// Success.
    exception         = 1,  /// An unhandled exception was thrown.
    failedToFetchList = 2,  /// The JSON list of images could not be fetched from server.
    imageJSONNotFound = 3,  /// The JSON list file could not be found.
    targetDirNotADir  = 4,  /// Target directory is a file or other non-directory.
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
        return ShellReturn.exception;
    }

    assert(0);
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
    import core.time : msecs, seconds;

    Configuration config;

    auto results = handleGetopt(args, config);

    if (results.helpWanted)
    {
        import prntscget.semver : PrntscgetSemVer, PrntscgetSemVerPrerelease;
        import std.format : format;
        import std.getopt : defaultGetoptPrinter;
        import std.path : baseName;

        enum banner = "prntscget v%d.%d.%d%s, built on %s".format(
            PrntscgetSemVer.majorVersion,
            PrntscgetSemVer.minorVersion,
            PrntscgetSemVer.patchVersion,
            PrntscgetSemVerPrerelease,
            __TIMESTAMP__);

        writeln(banner);

        immutable usageLine = "\nusage: %s [options]\n".format(args[0].baseName);
        defaultGetoptPrinter(usageLine, results.options);
        return ShellReturn.success;
    }

    /// JSON image list, fetched from the server
    JSONValue listJSON;

    if (config.cookie.length)
    {
        import std.algorithm.searching : canFind;
        import std.stdio : File;

        writefln(`fetching image list JSON and saving into "%s"...`, config.listFile);
        const listFileContents = getImageList(config.cookie, config.requestTimeoutSeconds);

        if (!listFileContents.canFind(`"result":{"success":true,`))
        {
            writeln("failed to fetch image list. incorrect cookie?");
            return ShellReturn.failedToFetchList;
        }

        listJSON = parseJSON(cast(string)listFileContents);
        immutable total = listJSON["result"]["total"].integer;
        writefln("%d %s found.", total, total.plurality("image", "images"));
        if (!config.dryRun) File(config.listFile, "w").writeln(listJSON.toPrettyString);
    }
    else if (!config.listFile.exists)
    {
        writefln(`image list JSON file "%s" does not exist.`, config.listFile);
        return ShellReturn.imageJSONNotFound;
    }

    if (!ensureImageDirectory(config.targetDirectory))
    {
        writefln(`"%s" is not a directory.`, config.targetDirectory);
        return ShellReturn.targetDirNotADir;
    }

    if (listJSON == JSONValue.init)  // (listJSON.type == JSONType.null_)
    {
        // A cookie was not supplied and the list JSON was never read
        listJSON = config.listFile
            .readText
            .parseJSON;
    }

    immutable numImages = cast(size_t)listJSON["result"]["total"].integer;

    if (!numImages)
    {
        writeln("no images to fetch.");
        return ShellReturn.success;
    }

    Appender!(RemoteImage[]) images;
    images.reserve(numImages);
    immutable numExistingImages = enumerateImages(images, listJSON, config, numImages);

    if (!images.data.length)
    {
        writefln("\nno images to fetch -- all %d are already downloaded.", numImages);
        return ShellReturn.success;
    }

    if (numExistingImages > 0)
    {
        writefln(" (skipping %d %s already in directory)", numExistingImages,
            numExistingImages.plurality("image", "images"));
    }

    immutable delayBetweenImages = (cast(int)(1000 * config.delayBetweenImagesSeconds)).msecs;
    auto eta = (images.data.length + (-1)) * delayBetweenImages;

    writeln("image list JSON file: ", config.listFile);
    writefln("delay between images: %.1f seconds", config.delayBetweenImagesSeconds);
    writeln("saving to directory:  ", config.targetDirectory);
    writefln("total images to download: %s -- this will take a MINIMUM of %s.",
        images.data.length, eta);

    downloadAllImages(images, config);

    writeln("done.");
    return ShellReturn.success;
}


/++
    Handles getopt arguments passed to the program.

    Params:
        args = Command-line arguments passed to the program.
        config = [Configuration] struct to set the members of.

    Returns:
        [std.getopt.GetoptResult] as returned by the call to [std.getopt.getopt].
 +/
auto handleGetopt(ref string[] args, out Configuration config)
{
    import std.getopt : getopt, getoptConfig = config;

    return getopt(args,
        getoptConfig.caseSensitive,
        "c|cookie",
            "Cookie to download gallery of (see README).",
            &config.cookie,
        "f|file",
            "Filename to save the JSON list of images to.",
            &config.listFile,
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
        "D|delay",
            "Delay between image downloads, in seconds.",
            &config.delayBetweenImagesSeconds,
        "t|timeout",
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
    bool outputPreamble;

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

            if (!outputPreamble)
            {
                write("verifying existing images ");
                outputPreamble = true;
            }

            scope(exit) stdout.flush();

            existingFile.seek(seekPos);
            const existingFileEnding = existingFile.rawRead(buf);

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

        images ~= RemoteImage(url, localPath, (i + config.startingImagePosition));
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
    import std.array : Appender;
    import core.time : msecs, seconds;

    enum initialAppenderSize = 1_048_576 * 2;

    immutable delayBetweenImages = (cast(int)(1000 * config.delayBetweenImagesSeconds)).msecs;
    immutable requestTimeout = config.requestTimeoutSeconds.seconds;

    Appender!(ubyte[]) buffer;
    buffer.reserve(initialAppenderSize);

    imageloop:
    foreach (immutable i, const image; images)
    {
        foreach (immutable retry; 0..config.retriesPerFile)
        {
            import std.net.curl : CurlException, CurlTimeoutException; //, HTTPStatusException;
            import std.stdio : stdout, write, writeln;

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
                    downloadImage(buffer, image.url, image.localPath, requestTimeout);

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
            catch (CurlTimeoutException e)
            {
                // Retry
                write('.');
                stdout.flush();
            }
            catch (CurlException e)
            {
                // Unexpected network error; retry
                write('.');
                stdout.flush();
            }
            /*catch (HTTPStatusException e)
            {
                // 404?
                write('!');
                stdout.flush();
            }*/
            catch (Exception e)
            {
                writeln();
                writeln(e.msg);
            }
        }
    }
}


/++
    Downloads an image from the `prnt.sc` (`prntscr.com`) server.

    Params:
        buffer = Appender to save the downloaded image to.
        url = HTTP URL to fetch.
        imagePath = Filename to save the downloaded image to.
        requestTimeout = Timeout to use when downloading.

    Returns:
        `true` if a file was successfully downloaded (including passing the
        image format ending checks); `false` if not.
 +/
bool downloadImage(ref Appender!(ubyte[]) buffer, const string url,
    const string imagePath, const Duration requestTimeout)
{
    import std.array : Appender;
    import std.net.curl : HTTP;
    import std.stdio : File;

    auto http = HTTP(url);
    http.dnsTimeout = requestTimeout;
    http.connectTimeout = requestTimeout;
    http.dataTimeout = requestTimeout;

    scope(exit) buffer.clear();

    http.onReceive = (ubyte[] data)
    {
        buffer.put(data);
        return data.length;
    };

    http.perform();
    if (http.statusLine.code != 200) return false;

    if (!hasValidPNGEnding(buffer.data) && !hasValidJPEGEnding(buffer.data))
    {
        // Interrupted download?
        return false;
    }

    File(imagePath, "w").rawWrite(buffer.data);
    return true;
}


/++
    Detects whether or not a passed array of bytes has a valid JPEG ending.

    Params:
        fileContents = Contents of a (possibly) JPEG file.
 +/
bool hasValidJPEGEnding(const ubyte[] fileContents)
{
    import std.algorithm.searching : endsWith;

    static immutable ubyte[2] eoi = [ 0xFF, 0xD9 ];
    return fileContents.endsWith(eoi[]);
}


/++
    Detects whether or not a passed array of bytes has a valid PNG ending.

    Params:
        fileContents = Contents of a (possibly) PNG file.
 +/
bool hasValidPNGEnding(const ubyte[] fileContents)
{
    import std.algorithm.searching : endsWith;

    static immutable ubyte[12] iend = [ 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4e, 0x44, 0xae, 0x42, 0x60, 0x82 ];
    return fileContents.endsWith(iend[]);
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
    Fetches the JSON list of images for a passed cookie from the `prnt.sc` (`prntscr.com`) server.

    Params:
        cookie = `__auth` cookie to fetch the gallery of.
        requestTimeoutSeconds = Request timeout when downloading the list.

    Returns:
        An array containing the response body of the request.
 +/
ubyte[] getImageList(const string cookie, const uint requestTimeoutSeconds)
{
    import std.array : Appender;
    import std.net.curl : HTTP;
    import core.time : seconds;

    enum url = "https://api.prntscr.com/v1/";
    enum postData = `{"jsonrpc":"2.0","method":"get_user_screens","id":1,"params":{"count":10000}}`;
    enum webform = "application/x-www-form-urlencoded";
    enum initialAppenderSize = 1_048_576;

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

    auto http = HTTP(url);
    immutable requestTimeout = requestTimeoutSeconds.seconds;
    http.dnsTimeout = requestTimeout;
    http.connectTimeout = requestTimeout;
    http.dataTimeout = requestTimeout;
    http.clearRequestHeaders();
    http.setPostData(postData, webform);

    foreach (immutable header, immutable value; headers)
    {
        http.addRequestHeader(header, value);
    }

    Appender!(ubyte[]) sink;
    sink.reserve(initialAppenderSize);

    http.onReceive = (ubyte[] data)
    {
        sink.put(data);
        return data.length;
    };

    http.perform();
    if (http.statusLine.code != 200) return null;

    return sink.data;
}


/++
    Chooses between two values based on if the passed numeric value is one or many.

    Params:
        num = Number of items.
        singular = Singular value.
        plural = Plural value.

    Returns:
        Either the singular or the plural form, based on the value of `num`.
 +/
T plurality(T, N)(N num, T singular, T plural)
{
    return ((num == 1) || (num == -1)) ? singular : plural;
}
