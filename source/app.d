/++
    Lightshot `prnt.sc` (and `prntscr.com`) gallery downloader.

    https://app.prntscr.com/en/index.html
 +/
module prntscget;

private:

import std.array : Appender;
import std.stdio : writefln, writeln;
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

    /// The minimum image size in bytes to consider as a successful download.
    uint minFileSizeThreshold = 400;

    /// Directory to save images to.
    string targetDirectory = "images";

    /// Reques timeout when downloading an image.
    uint requestTimeoutSeconds = 60;

    /// How many seconds to wait inbetween image downloads.
    uint delayBetweenImagesSeconds = 60;

    /// The number of images to skip when downloading (the starting position).
    uint startingImagePosition;

    /// How many images to download.
    uint numberToDownload = uint.max;

    /// Whether or not this is a dry run.
    bool dryRun;
}


/++
    Program entry point.

    Params:
        args = Arguments passed at the command line.

    Returns:
        zero on success, non-zero on errors.
 +/
int main(string[] args)
{
    import std.algorithm.comparison : min;
    import std.array : Appender;
    import std.file : exists, readText;
    import std.getopt : defaultGetoptPrinter, getopt, getoptConfig = config;
    import std.json : JSONException, parseJSON;
    import std.range : drop, enumerate, retro, take;
    import core.time : seconds;

    Configuration config;
    string specifiedCookie;

    auto results = getopt(args,
        getoptConfig.caseSensitive,
        getoptConfig.passThrough,
        "c|cookie",
            "Cookie to download gallery of (see README).",
            &specifiedCookie,
        "d|dir",
            "Target image directory.",
            &config.targetDirectory,
        "s|start",
            "Starting image position.",
            &config.startingImagePosition,
        "n|num",
            "Number of images to download.",
            &config.numberToDownload,
        "r|retries",
            "How many times to retry downloading an image.",
            &config.retriesPerFile,
        "delay",
            "Delay between image downloads, in seconds.",
            &config.delayBetweenImagesSeconds,
        "timeout",
            "Download attempt read timeout, in seconds.",
            &config.requestTimeoutSeconds,
        "min",
            "Minimum file size to accept as a successful download (in bytes).",
            &config.minFileSizeThreshold,
        "dry-run",
            "Download nothing, only echo what would be done.",
            &config.dryRun,
    );

    if (results.helpWanted)
    {
        import std.path : baseName;
        writefln("usage: %s [options] [json file (target.json)]", args[0].baseName);
        defaultGetoptPrinter(string.init, results.options);
        return 0;
    }

    if (specifiedCookie.length)
    {
        import std.algorithm.searching : canFind;

        writefln(`fetching image list JSON and saving into "%s"...`, config.listFile);
        const listFileContents = getImageList(specifiedCookie);

        if (!listFileContents.canFind(`"result":{"success":true,`))
        {
            writeln("failed to fetch image list. incorrect cookie?");
            return 1;
        }

        immutable imageListJSON = parseJSON(cast(string)listFileContents);
        writefln("%d image(s) found.", imageListJSON["result"]["total"].integer);

        try
        {
            import std.stdio : File;
            File(config.listFile, "w").writeln(imageListJSON.toPrettyString);
        }
        catch (JSONException e)
        {
            writefln(`FAILED TO PARSE LIST FILE "%s"`, config.listFile);
            writeln(e);
            return 1;
        }
        catch (Exception e)
        {
            writefln(`FAILED TO WRITE LIST FILE "%s"`, config.listFile);
            writeln(e);
            return 1;
        }
    }

    if (!config.listFile.exists)
    {
        writefln(`image list JSON file "%s" does not exist.`, config.listFile);
        return 1;
    }

    try
    {
        if (!ensureImageDirectory(config))
        {
            writefln(`"%s" is not a directory; remove it and try again.`, config.targetDirectory);
            return 1;
        }
    }
    catch (Exception e)
    {
        writefln(`FAILED TO ENSURE TARGET IMAGE DIRECTORY "%s"`, config.targetDirectory);
        writeln(e);
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
    uint numExistingImages;

    auto range = listJSON["result"]["screens"]
        .array
        .retro
        .drop(config.startingImagePosition)
        .take(min(config.numberToDownload, numImages))
        .enumerate;

    foreach (immutable i, imageJSON; range)
    {
        import std.array : replace, replaceFirst;
        import std.file : exists, getSize;
        import std.path : buildPath, extension;

        immutable url = imageJSON["url"].str;
        immutable filename = imageJSON["date"].str
                .replace(" ", "_")
                .replaceFirst(":", "h")
                .replaceFirst(":", "m") ~ url.extension;
        immutable localPath = buildPath(config.targetDirectory, filename);

        if (!localPath.exists || (getSize(localPath) < config.minFileSizeThreshold))
        {
            images ~= RemoteImage(url, localPath, i);
        }
        else
        {
            ++numExistingImages;
        }
    }

    if (!images.data.length)
    {
        writefln("no images to fetch -- all %d are already downloaded.", numImages);
        return 0;
    }

    if (numExistingImages > 0)
    {
        writefln("(skipping %d images already in directory.)", numExistingImages);
    }

    writefln("total images: %s -- this will take a MINIMUM of %s.",
        images.data.length, images.data.length*config.delayBetweenImagesSeconds.seconds);

    downloadAllImages(images, config);

    writeln("done.");
    return 0;
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

                immutable success = config.dryRun || downloadImage(image.url,
                    image.localPath, requestTimeout, config.minFileSizeThreshold);

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
                writefln("EXCEPTION CAUGHT! index %d retry %d", i, retry);
                writeln(e);
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
bool downloadImage(const string url, const string imagePath,
    const Duration requestTimeout, const uint minFileSizeThreshold)
{
    import requests : Request;

    Request req;
    req.timeout = requestTimeout;
    req.keepAlive = false;
    auto res = req.get(url);

    // Confirm size so we didn't download a 366-byte 505 info page
    if ((res.code == 200) && (res.responseBody.length > minFileSizeThreshold))
    {
        import std.stdio : File;
        auto file = File(imagePath, "w");
        file.rawWrite(res.responseBody.data);
        return true;
    }

    return false;
}


/++
    Ensures the target image directory exists, creating it if it does not and
    returning false if it fails to.

    Params:
        config = The current [Configuration].

    Returns:
        `true` if the directory already exists or if it was succesfully created;
        `false` if it could not be.
 +/
bool ensureImageDirectory(const Configuration config)
{
    import std.file : exists, isDir, mkdir;

    if (!config.targetDirectory.exists)
    {
        mkdir(config.targetDirectory);
        return true;
    }
    else if (!config.targetDirectory.isDir)
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
    auto res = req.post(url, post, "application/x-www-form-urlencoded");
    return res.responseBody.data;
}
