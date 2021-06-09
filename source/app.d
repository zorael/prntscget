///
module prntscget;

import std.array : Appender;
import std.stdio;
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
    uint minFileSizeThershold = 400;

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
}


///
void main(string[] args)
{
    import std.algorithm.comparison : min;
    import std.array : Appender;
    import std.file : readText;
    import std.getopt : defaultGetoptPrinter, getopt, getoptConfig = config;
    import std.json : parseJSON;
    import std.range : drop, retro, take;
    import core.time : seconds;

    Configuration config;

    auto results = getopt(args,
        getoptConfig.caseSensitive,
        getoptConfig.passThrough,
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
            "Minimum file size to accept as a successful download.",
            &config.minFileSizeThershold,
    );

    writeln(config);

    if (results.helpWanted || (args.length != 2))
    {
        import std.path : baseName;
        writefln("usage: %s [options] [json file]", args[0].baseName);
        defaultGetoptPrinter(string.init, results.options);
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
        import std.file : exists;
        import std.path : buildPath, extension;

        immutable url = imageJSON["url"].str;
        immutable filename = imageJSON["date"].str
                .replace(" ", "_")
                .replaceFirst(":", "h")
                .replaceFirst(":", "m") ~ url.extension;
        immutable localPath = buildPath(config.targetDirectory, filename);

        if (!localPath.exists)
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
        foreach (immutable retry; 0..config.retriesPerFile)
        {
            import requests : TimeoutException;

            try
            {
                if ((i != 0) && ((i != (images.data.length+(-1))) || (i == 1)))
                {
                    import core.thread : Thread;
                    Thread.sleep(delayBetweenImages);
                }

                if (retry == 0)
                {
                    writef("%s --> %s: ", image.url, image.localPath);
                    stdout.flush();
                }

                immutable success = downloadImage(image.url, image.localPath,
                    requestTimeout, config.minFileSizeThershold);

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
