# Loaderoo Product Vision

Loaderoo is an open-source, native macOS app for people who collect adult videos. Open Loaderoo to find recent Usenet uploads of videos missing from your library and recognize them by their preview images. When you choose a download, you should be able to follow it from the indexer listing to the finished video in your studio folder.

## Browse what you can download

Setup requires a valid personal PRDB API key. PRDB’s public API supplies titles, studios, release dates, preview images and known file hashes. From the first release, you can connect multiple Newznab-compatible Usenet indexers and browse offers from all of them in one feed. You install and run SABnzbd separately to download and unpack them. The expected setup is a SABnzbd container on your local network, with its completed-download folder accessible from the Mac.

Loaderoo automatically matches indexer listings to PRDB videos. A video appears in the feed once at least one listing has a confirmed match and the video is missing from your library. Ambiguous listings stay out of the feed until PRDB can resolve them. Loaderoo rechecks them in the background as new information becomes available.

The feed sorts by Usenet posting time, newest first. A video released last year and uploaded today can appear among today’s posts. Each entry shows the preview image when available, the title and studio, and the quality when known. When several indexers offer the same video, the entry has one **Download** action. Loaderoo chooses the source and NZB automatically, trying the user’s preferred quality first when set. Opening the title shows the individual offers, each with a Download action for that exact NZB.

Loaderoo checks ownership by PRDB video ID. Once a file on disk is linked to that ID, the feed hides every offer for the video, regardless of the quality of the file or the offer. For example, owning *Night Shift* in 1080p hides its 4K upload and any upload with unknown quality. A local copy of unknown quality counts just as well.

## Recognize what you already own

Choose the folders that hold your existing videos. Loaderoo scans them in place, computes each file’s OSHash, and checks it against PRDB’s known hash-to-title associations. A uniquely matched file appears alongside its PRDB title even if someone renamed the file or stored it outside a studio folder. You can see the matching file and its location in your library.

Local library entries also have visual previews. They use PRDB artwork when available and a still from the video when possible. An unidentified file stays visible in the library. If a library drive is disconnected, Loaderoo remembers the last known match and shows that the file is currently offline.

## Follow the download into its studio folder

Click **Download** on the video you want. Loaderoo sends one NZB to SABnzbd and records its source indexer and PRDB video ID with the job so you can see which release it used. The extracted video inherits that title through the job, even after an app restart. This association is sufficient to file the video. A missing or conflicting hash leaves the selected title in force.

After SABnzbd finishes post-processing, Loaderoo uses the job’s reported completion path to locate the video. During setup, you map the container’s completed-download folder to the corresponding folder mounted on the Mac. If the share is offline when the job finishes, Loaderoo keeps the title and job together and resumes filing when the folder is accessible again.

Choose a destination folder for completed videos. By default, Loaderoo files a confirmed video under its PRDB studio and names it after its PRDB title, preserving the media extension. For example, a video titled *Night Shift* from *Studio North* lands at `Studio North/Night Shift.mp4` inside the destination. A filename setting lets you keep the original extracted filename in the same studio folder. If the name is already taken, Loaderoo preserves the existing file and chooses an available name automatically. Once filed, the video joins the local catalog and its final path is visible from the release.

## Give unresolved downloads a place

If Loaderoo cannot assign a completed download to a title or studio, it keeps the extracted filename. By default, the file stays in SABnzbd’s completed-download folder. A setting lets you send such files to an `Unsorted` folder inside your chosen destination instead.

In either location, Loaderoo remembers the file’s path and what it needs to finish filing. For a download with no confirmed title, it keeps the file’s OSHash and checks again as PRDB publishes new hash associations. If a later hash uniquely identifies the title and its studio is known, Loaderoo automatically moves the file into that studio’s folder, applies your filename preference, and updates its catalog entry. A download with a confirmed title but a missing studio can be filed as soon as PRDB supplies the studio. Automatic moves apply to tracked downloads. Scanning your existing library identifies files in place.

## Technical foundation

Follow Vieweroo’s Swift 6 and Swift Package Manager layout, targeting macOS 14 or later on Apple Silicon. Build the interface in SwiftUI, using AppKit where a native Mac interaction needs it. Keep scanning, matching, download tracking and filing in a testable Swift core. Persist the catalog and job references locally in SQLite through GRDB so that reopening Loaderoo can reconnect a release to its SABnzbd job or its file. [Vieweroo architecture](https://github.com/prdb-net/vieweroo/blob/main/ARCHITECTURE.md)

Resolve indexer listing metadata through `POST /releases/resolve` before offering a download. Use the resulting PRDB title ID throughout the download and filing workflow. Use OSHash and byte size with `POST /videos/identify` for files discovered in an existing library and for downloads whose title is still unknown. [PRDB release resolution](https://github.com/prdb-net/prdb-sdk/blob/main/docs/release-resolution.md) · [PRDB video hashing](https://github.com/prdb-net/prdb-sdk/blob/main/docs/video-hashing.md)
