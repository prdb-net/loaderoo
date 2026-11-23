# Loaderoo

Loaderoo is a native macOS app for discovering Usenet releases for an adult video library. Its live feed reads Newznab indexers and resolves their uploads through the PRDB public API. Loaderoo identifies existing videos, sends selected NZBs to your SABnzbd instance and files completed downloads by studio. See the [product vision](VISION.md).

## Build and run

On an Apple Silicon Mac with macOS 14 or later and a Swift 6.1 or newer toolchain, run:

```sh
scripts/build-app
open dist/Loaderoo.app
```

Use `swift run Loaderoo` for development and `swift test` for the offline tests. Swift Package Manager fetches GRDB on the first build.

For visual checks, launch the packaged app. The build script links against the selected macOS SDK, keeps the macOS 14 deployment target and verifies both versions in the executable.

Test macOS permission prompts with the app bundle. Local builds use ad hoc signing. For distribution outside the Mac App Store, set `CODE_SIGN_IDENTITY` to your Developer ID Application identity when running `scripts/build-app`. A consistent Apple-issued signing identity lets macOS recognize Loaderoo across updates. [Apple’s local network privacy technote](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy)

## Connect the live feed

Choose **Set Up Connections**. Enter your personal PRDB API key and the API address and key for each Newznab indexer. The address field accepts an endpoint such as `https://indexer.example/api` or a bare host URL. A bare host uses `/api`. The default category is 6000 (adult). Use the IDs supported by your indexer, or clear the field to search all categories. Choose **Save Connections**. You can edit the entries later using **Connections** at the bottom of the sidebar.

While the live feed is open, Loaderoo reads the latest search page (up to 100 uploads per indexer) every 15 minutes. **Refresh** checks for new uploads immediately. Scrolling to the end of the catalog or choosing **Load earlier uploads** reads the next available page from each indexer. Loaderoo respects service retry deadlines. One unavailable indexer leaves the others usable.

Loaderoo opens as a resizable window that fills the available desktop on its display. Use the left sidebar to switch between Catalog, Downloads and Library. Press **⌘F** to focus the search field in the current view.

In **Catalog**, type a title, studio, original release name or indexer to search the local catalog. Press Return or choose **Search indexers** to query older releases directly. Search results have their own pagination. By default the grid and compact list show titles with a PRDB preview. Turn off **Filters → Only titles with previews** to include the others. Loaderoo remembers this choice. Refresh checks again for missing previews last checked over 15 minutes ago.

Hover over a catalog image to play its scene previews when PRDB provides a sprite sheet. Moving the pointer away restores the cover. Titles with only a sprite sheet use its first frame as the cover. Open a title to browse the available still images and see its cast. Click the main preview when the magnifier appears to see more detail. Use the arrow keys to browse images and Escape to return to the selected image.

Filter by studio, quality, indexer or posting date, and select a title to compare the resolution and file size of each offer. The detail panel shows your preferred quality first, then the other resolutions from highest to lowest. Hover over a release name to read it in full. Press Escape to close the panel.

Only confirmed single-video matches appear. Offers for the same PRDB video share an entry with its preview artwork when available, its studio, source names and known qualities. The newest Usenet posting time determines the order. Titles with no reported Usenet posting time appear last. The RSS publication date describes indexing and is kept separate. [Newznab API](https://newznab.readthedocs.io/en/latest/misc/api.html#search) Loaderoo keeps recently seen listings for 90 days after their last appearance, including unresolved entries, and checks for due PRDB retries once a minute while the feed is open. Cached matches survive restarts.

Connection settings (including API keys) and feed data are stored locally in SQLite under `~/Library/Application Support/net.prdb.loaderoo/Live/`, in a directory restricted to your macOS account. The database is unencrypted. PRDB receives release names, posting times and available source identifiers, sizes and category hints for matching.

## Match existing videos

Open **Library → Manage Folders** and choose the folders you want to scan. Loaderoo reads video files in place and sends the basename, byte count and OSHash to PRDB. A unique OSHash match hides every upload for that video ID. Unmatched files remain in the library. **Scan Library** picks up filesystem changes and retries unresolved hashes after 24 hours. Offline folders retain their matches. Removing a folder removes its scan records and preserves the files on disk.

## Download and file a release

Open **Connections → SABnzbd**. Enter the API address of your running instance and its full API key. Saving the connection checks read access to the queue. You can assign a SABnzbd category.

On macOS 15 or later, the first connection to a SABnzbd server or indexer on your local network can trigger a macOS permission prompt. Choose **Allow**. If you previously denied access, open **System Settings → Privacy & Security → Local Network** and turn on **Loaderoo**. Leave the SABnzbd form open and it will retry the queue check when access becomes available. You can also choose **Try Again**.

For example, if SABnzbd reports completed jobs under `/downloads/complete` and Finder sees that folder at `/Volumes/Media/Completed`, enter the former as **Container folder** and select the latter as **Mounted on Mac**. Optionally choose a **Studio library** destination. Loaderoo otherwise leaves completed files in place.

In the catalog grid or list, **Download** tries the newest upload first, preferring the larger file when posting times match. Set **Connections → SABnzbd → Preferred quality** to try releases of that quality first. If none has a usable NZB, Loaderoo tries the other releases in the same order.

To choose a specific NZB, click the title and use **Download** beneath the release you want. Loaderoo requests only that NZB and records the chosen release and indexer with the job.

SABnzbd uses the indexer’s NZB name for the download folder, falling back to the listing title when the indexer supplies no name. **Downloads** shows active jobs, completed jobs and jobs needing attention. The table includes progress and time remaining when SABnzbd reports them. Search by title, release name or path. Select a row to see the SABnzbd job name, completion path, final video location and any filing issue. **Show in Finder** reveals the filed video. Loaderoo remembers the submission across restarts. If the submission response is lost, it recovers the job from its unique upload filename once the job reaches SABnzbd’s history. It can only reconcile a job that SABnzbd still retains.

After post-processing, Loaderoo files a single completed video under `Studio/Video title.ext`, or keeps the extracted filename if you selected that option. It preserves existing destination files by choosing an available name. The PRDB title follows the job throughout filing. Unknown studios can wait in place or in **Unsorted**. When a studio becomes available, Loaderoo can finish the move. A job folder containing several videos stays in place for review. Filesystem access and job tracking resume while the app is open. [SABnzbd API reference](https://sabnzbd.org/wiki/configuration/4.5/api)

## Try the local download demo

Open **Workspace → Open Local Demo**, or run `swift run Loaderoo --demo`. The demo uses two simulated indexers, simulated PRDB and simulated SABnzbd. It needs no accounts or live connections.

1. Open **Recent uploads**. Two indexers offer *Night Shift* from *Studio North* with one **Download** action.
2. Click **Download** and open **Downloads** to see the selected indexer. To try recovery, quit while the job is pending, relaunch and reopen the demo. Its job becomes ready twelve seconds after submission.
3. Open **Library** and choose **Show in Finder**. Loaderoo maps the simulated container’s completed path to a local folder and moves the sample MP4 into `Library/Studio North/Night Shift.mp4`. The title disappears from the demo feed.

The demo keeps its own queue, catalog and media under `~/Library/Application Support/net.prdb.loaderoo/Demo/`. To start in a fresh demo directory, run `LOADEROO_DEMO_ROOT="$(mktemp -d)" swift run Loaderoo`.
