/++
    Lightshot `prnt.sc` (and `prntscr.com`) gallery downloader.

    See_Also: https://app.prntscr.com/en/index.html
 +/
module prntscget.app;

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
    this(const string url, const string localPath, const size_t number) pure @safe @nogc nothrow
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

    /// The offset number of images in the list to skip considering.
    uint imageOffset;

    /// The number of images to effectively skip when downloading (e.g. the index starting position).
    uint imagesToSkip;

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
    noCookieInJSON    = 5,  /// The JSON file is old and does not have a cookie saved in it.
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
    import std.algorithm.comparison : min;
    import std.array : array;
    import std.file : exists;
    import std.json : parseJSON;
    import std.range : drop, take;
    import std.stdio : writefln, writeln;
    import core.time : msecs;

    Configuration config;

    auto results = handleGetopt(args, config);

    if (results.helpWanted)
    {
        printHelp(results, args);
        return ShellReturn.success;
    }

    /// JSON image list, fetched from the server
    JSONValue listJSON;

    /// HTTP GET request headers to use when downloading
    string[string] headers;

    if (config.cookie.length)
    {
        import std.algorithm.searching : canFind;
        import std.stdio : File;

        headers = buildHeaders(config.cookie);

        writefln(`fetching image list and saving into "%s"...`, config.listFile);
        const listFileContents = getImageList(headers, config.requestTimeoutSeconds);

        if (!listFileContents.canFind(`"result":{"success":true,`))
        {
            writeln("failed to fetch image list. incorrect cookie?");
            return ShellReturn.failedToFetchList;
        }

        listJSON = parseJSON(listFileContents);
        listJSON["cookie"] = config.cookie;  // Store the cookie! We need it nowadays.
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

    static if (__VERSION__ >= 2087)
    {
        import std.json : JSONType;
        alias jsonNullType = JSONType.null_;
    }
    else
    {
        import std.json : JSON_TYPE;
        alias jsonNullType = JSON_TYPE.NULL;
    }

    if (listJSON.type == jsonNullType)
    {
        import std.file : readText;

        // A cookie was not supplied and the list JSON was never read
        listJSON = config.listFile
            .readText
            .parseJSON;

        if ("cookie" !in listJSON)
        {
            writeln("your JSON file does not contain a cookie and must be regenerated.");
            return ShellReturn.noCookieInJSON;
        }

        headers = buildHeaders(listJSON["cookie"].str);
    }

    immutable numImages = cast(size_t)listJSON["result"]["total"].integer;

    if (!numImages)
    {
        writeln("no images to fetch.");
        return ShellReturn.success;
    }

    Appender!(RemoteImage[]) images;
    images.reserve(min(numImages, config.numToDownload));
    immutable numExistingImages = enumerateImages(images, listJSON, config);

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

    const imageSelection = images.data
        .array
        .drop(config.imagesToSkip)
        .take(min(config.numToDownload, numImages));

    immutable delayBetweenImages = (cast(int)(1000 * config.delayBetweenImagesSeconds)).msecs;
    immutable eta = (images.data.length + (-1)) * delayBetweenImages;

    writeln("image list JSON file: ", config.listFile);
    writefln("delay between images: %.1f seconds", config.delayBetweenImagesSeconds);
    writeln("saving to directory:  ", config.targetDirectory);
    writefln("total images to download: %s -- this will take a MINIMUM of %s.",
        images.data.length, eta);

    downloadAllImages(imageSelection, config, headers);

    writeln("done.");
    return ShellReturn.success;
}


/++
    Handles getopt arguments passed to the program.

    Params:
        args = Command-line arguments passed to the program.
        config = out [Configuration] to set the members of.

    Returns:
        [std.getopt.GetoptResult] as returned by the call to [std.getopt.getopt].
 +/
auto handleGetopt(ref string[] args, out Configuration config) /*@safe*/
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
        "o|offset",
            "Images to skip considering, before checking for existing images.",
            &config.imageOffset,
        "s|skip",
            "Images to effectively skip downloading, after applying offset and checking for existing files.",
            &config.imagesToSkip,
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
    Prinst the `getopt` help screen to the terminal.

    Params:
        results = The results as returned from the `getopt` call.
        args = The shell arguments passed to the program.
 +/
void printHelp(GetoptResult results, const string[] args)
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

    immutable usageLine = "%s\n\nusage: %s [options]\n"
        .format(banner, args[0].baseName);
    defaultGetoptPrinter(usageLine, results.options);
}


/++
    Enumerate images, skipping existing ones.

    Params:
        images = [std.array.Appender] containing references to all images to download.
        listJSON = JSON list of images to download.
        config = The current [Configuration] of all getopt values aggregated.

    Returns:
        The number of images that should be downloaded.
 +/
uint enumerateImages(ref Appender!(RemoteImage[]) images,
    const JSONValue listJSON,
    const Configuration config)
{
    import std.range : drop, enumerate, retro;

    uint numExistingImages;
    bool outputPreamble;

    auto range = listJSON["result"]["screens"]
        .array
        .retro
        .drop(config.imageOffset)
        .enumerate;

    foreach (immutable i, imageJSON; range)
    {
        import std.array : replace, replaceFirst;
        import std.file : exists;
        import std.path : buildPath, extension;

        // Break early to cover the case of numToDownload == 0
        if (images.data.length == config.numToDownload) break;

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
            const existingFileEnding = existingFile.rawRead(buf[]);

            if (hasValidJPEGEnding(existingFileEnding) || hasValidPNGEnding(existingFileEnding))
            {
                write('.');
                ++numExistingImages;
                // continue without appending the image entry
                continue;
            }
            else
            {
                // drop down to append the image entry and re-download the file
                write('!');
            }
        }

        images ~= RemoteImage(url, localPath, (i + config.imageOffset));
    }

    return numExistingImages;
}

/++
    Downloads all images in the passed `images` list.

    Images are saved to the filename specified in each [RemoteImage.localPath].

    Params:
        images = The list of images to download.
        config = The current program [Configuration].
        headers = HTTP GET headers to supply when downloading.
 +/
void downloadAllImages(const RemoteImage[] images,
    const Configuration config,
    const string[string] headers)
{
    import std.array : Appender;
    import core.time : msecs, seconds;

    enum initialAppenderSize = 1_048_576 * 4;

    immutable delayBetweenImages = (cast(int)(1000 * config.delayBetweenImagesSeconds)).msecs;
    immutable requestTimeout = config.requestTimeoutSeconds.seconds;

    Appender!(ubyte[]) buffer;
    buffer.reserve(initialAppenderSize);

    imageloop:
    foreach (immutable i, const image; images)
    {
        import std.stdio : writeln;

        scope(exit) writeln();

        retryloop:
        foreach (immutable retry; 0..config.retriesPerFile)
        {
            import std.net.curl : CurlException, CurlTimeoutException; //, HTTPStatusException;
            import std.stdio : stdout, write;

            try
            {
                if (!config.dryRun && (i != 0) && ((i != (images.length+(-1))) || (i == 1)))
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

                immutable code = config.dryRun ? 200 :
                    downloadImage(buffer, image.url, image.localPath, requestTimeout, headers);

                switch (code)
                {
                case 200:
                    // HTTP OK
                    write("ok");
                    //stdout.flush();
                    continue imageloop;

                case 0:
                    // magic number, non-image file was saved
                    goto default;

                case 403:  // HTTP Forbidden
                    // Throttled?
                    write(" !", code, "! ");
                    stdout.flush();
                    continue retryloop;

                default:
                    //write(" ?", code, "? ");
                    write('.');
                    stdout.flush();
                    continue retryloop;
                }
            }
            catch (CurlTimeoutException e)
            {
                // Retry
                write(" (", e.msg, ") ");
                stdout.flush();
                //continue retryloop;
            }
            catch (CurlException e)
            {
                // Unexpected network error; retry
                write(" (", e.msg, ") ");
                stdout.flush();
                //continue retryloop;
            }
            /*catch (HTTPStatusException e)
            {
                // 404?
                write(" !", e.msg, "! ");
                stdout.flush();
                //continue retryloop;
            }*/
            catch (Exception e)
            {
                writeln();
                writeln(e);
                writeln("FIXME: add a catch for this type of exception");
                //continue retryloop;
            }
        }
    }
}


/++
    Builds an associative array of HTTP GET headers to use when requesting
    information of images from the server.

    Params:
        cookie = The gallery `__auth` cookie.

    Returns:
        A `string[string]` associative array of headers.
 +/
string[string] buildHeaders(const string cookie) pure @safe nothrow
{
    return
    [
        "user-agent"      : "Mozilla/5.0 (X11; Linux x86_64; rv:93.0) Gecko/20100101 Firefox/93.0",
        "accept"          : "text/html,application/xhtml+xml,application/xml;q=0.9,image/png,image/jpeg,*/*;q=0.8",
        "accept-language" : "en-US,en;q=0.5",
        "accept-encoding" : "gzip, deflate, br",
        "dnt"             : "1",
        "cookie"          : "G_ENABLED_IDPS=google; G_AUTHUSER_H=0; auth_=" ~ cookie,
        "upgrade-insecure-requests" : "1",
        "sec-fetch-dest"  : "document",
        "sec-fetch-mode"  : "navigate",
        "sec-fetch-site"  : "none",
        "sec-fetch-user"  : "?1",
        "sec-GPC"         : "1",
    ];
}


/++
    Downloads an image from the `prnt.sc` (`prntscr.com`) server.

    Params:
        buffer = Appender to save the downloaded image to.
        url = HTTP URL to fetch.
        imagePath = Filename to save the downloaded image to.
        requestTimeout = Timeout to use when downloading.
        headers = HTTP GET headers to supply when downloading.

    Returns:
        The HTTP code encountered when attempting to download the image.
 +/
int downloadImage(ref Appender!(ubyte[]) buffer,
    const string url,
    const string imagePath,
    const Duration requestTimeout,
    const string[string] headers)
{
    import std.array : Appender;
    import std.net.curl : HTTP;
    import std.stdio : File;

    auto http = HTTP(url);
    http.dnsTimeout = requestTimeout;
    http.connectTimeout = requestTimeout;
    http.dataTimeout = requestTimeout;
    http.clearRequestHeaders();

    foreach (immutable header, immutable value; headers)
    {
        http.addRequestHeader(header, value);
    }

    scope(exit) buffer.clear();

    http.onReceive = (ubyte[] data)
    {
        buffer.put(data);
        return data.length;
    };

    http.perform();

    if (http.statusLine.code == 200)
    {
        if (!hasValidPNGEnding(buffer.data) && !hasValidJPEGEnding(buffer.data))
        {
            // Interrupted download? Cloudflare error page?
            return 0;
        }

        File(imagePath, "w").rawWrite(buffer.data);
    }

    return http.statusLine.code;
}


/++
    Detects whether or not a passed array of bytes has a valid JPEG ending.

    Params:
        fileContents = Contents of a (possibly) JPEG file.
 +/
bool hasValidJPEGEnding(const ubyte[] fileContents) pure @safe @nogc nothrow
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
bool hasValidPNGEnding(const ubyte[] fileContents) pure @safe @nogc nothrow
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
bool ensureImageDirectory(const string targetDirectory) @safe
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
        headers = HTTP GET headers to supply when fetching the list.
        requestTimeoutSeconds = Request timeout when downloading the list.

    Returns:
        An array containing the response body of the request.
 +/
string getImageList(const string[string] headers, const uint requestTimeoutSeconds)
{
    import std.array : Appender;
    import std.net.curl : HTTP;
    import core.time : seconds;

    enum url = "https://api.prntscr.com/v1/";
    enum postData = `{"jsonrpc":"2.0","method":"get_user_screens","id":1,"params":{"count":10000}}`;
    enum webform = "application/x-www-form-urlencoded";
    enum initialAppenderSize = 1_048_576 * 2;

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

    return cast(string)sink.data;
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
T plurality(T, N)(N num, T singular, T plural) pure @safe @nogc nothrow
{
    return ((num == 1) || (num == -1)) ? singular : plural;
}
