///
module prntscget;

import std.array : Appender;
import std.stdio : writefln, writeln;
import core.time : Duration;


///
struct RemoteImage
{
    ///
    string url;

    ///
    string localPath;
}


///
struct Configuration
{
    ///
    string listFile = "target.json";

    ///
    uint retriesPerFile = 100;

    ///
    uint minFileSizeThreshold = 400;

    ///
    string targetDirectory = "images";

    ///
    uint requestTimeoutSeconds = 60;

    ///
    uint delayBetweenImagesSeconds = 60;

    ///
    uint start;

    ///
    uint numberToDownload = uint.max;

    ///
    bool dryRun;
}


///
void main(string[] args)
{
    import std.algorithm.comparison : min;
    import std.array : Appender;
    import std.file : exists, readText;
    import std.getopt : defaultGetoptPrinter, getopt, getoptConfig = config;
    import std.json : parseJSON;
    import std.range : drop, retro, take;
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
            "Starting image position",
            &config.start,
        "n|num",
            "Number of images to download",
            &config.numberToDownload,
        "r|retries",
            "How many times to retry downloading an image.",
            &config.retriesPerFile,
        "delay",
            "Delay between image downloads, in seconds.",
            &config.delayBetweenImagesSeconds,
        "timeout",
            "Download attempt read timeout.",
            &config.requestTimeoutSeconds,
        "min",
            "Minimum file size to accept as a successful download (in bytes).",
            &config.minFileSizeThreshold,
        "dry-run",
            "Download nothing, only echo what would be done.",
            &config.dryRun,
    );

    writeln(config);

    if (results.helpWanted || (args.length != 2))
    {
        import std.path : baseName;
        writefln("usage: %s [options] [json file]", args[0].baseName);
        defaultGetoptPrinter(string.init, results.options);
        return;
    }

    if (specifiedCookie.length)
    {
        import std.algorithm.searching : canFind;

        const listFileContents = getImageList(specifiedCookie);

        if (listFileContents.canFind(`"result":{"success":true,`))
        {
            // Failed, probably incorrect cookie
            writeln("failed to fetch image list. incorrect cookie?");
            return;
        }

        try
        {
            import std.stdio : File;
            auto listFile = File(config.listFile, "w");
            listFile.writeln(listFileContents);
        }
        catch (Exception e)
        {
            writefln(`FAILED TO WRITE LIST FILE "%s"`, config.listFile);
            writeln(e);
            return;
        }
    }

    if (!config.listFile.exists)
    {
        writefln(`image list JSON file "%s" does not exist.`, config.listFile);
        return;
    }

    try
    {
        if (!ensureImageDirectory(config))
        {
            writeln(`"%s" is not a directory; remove it and try again.`);
            return;
        }
    }
    catch (Exception e)
    {
        writeln();
        writeln("FAILED TO ENSURE TARGET IMAGE DIRECTORY");
        writeln(e);
        writeln();
        return;
    }

    auto listJSON = config.listFile
        .readText
        .parseJSON;
    immutable numImages = listJSON["result"]["total"].integer;

    if (!numImages)
    {
        writeln("no images to fetch.");
        return;
    }

    Appender!(RemoteImage[]) images;
    images.reserve(numImages);

    auto range = listJSON["result"]["screens"]
        .array
        .retro
        .drop(config.start)
        .take(min(config.numberToDownload, numImages));

    foreach (imageJSON; range)
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
            images ~= RemoteImage(url, localPath);
        }
        else
        {
            writeln(localPath, " exists");
        }
    }

    if (!images.data.length)
    {
        writefln("no images to fetch -- all %d are already downloaded.", numImages);
        return;
    }

    writefln("total images: %s -- this will take a MINIMUM of %s.",
        images.data.length, images.data.length*config.delayBetweenImagesSeconds.seconds);

    downloadAllImages(config, images);
    writeln("done.");
}


///
void downloadAllImages(const Configuration config, const Appender!(RemoteImage[]) images)
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
            import requests : TimeoutException;

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
                    writef("%s --> %s: ", image.url, image.localPath);
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
            catch (Exception e)
            {
                writeln();
                writefln("EXCEPTION CAUGHT! index %d retry %d", i, retry);
                writeln(e);
                writeln();
            }
        }
    }
}


///
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


///
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


///
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
