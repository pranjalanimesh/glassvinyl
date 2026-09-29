// Runs inside YouTube Music's page (main world), where its player, queue store and
// command system live. PlayerBridge sends this file with every call; the version guard
// keeps a single instance per page load.
//
// Queue changes go through YouTube Music's own commands (resolveCommand), the same path
// its menus use, so the server-side queue stays in sync.
if (!window.__ytp || window.__ytp.version !== 2) {
  window.__ytp = (() => {
    const $ = (sel) => document.querySelector(sel);
    const text = (t) => (t ? (t.runs ? t.runs.map((r) => r.text).join('') : t.simpleText || '') : '');
    const app = () => $('ytmusic-app');
    const resolve = (command) => $('ytmusic-player-bar').polymerController.resolveCommand(command);
    const player = () => $('#movie_player');
    const items = () => $('#queue')?.queue?.store?.store?.getState().queue.items || [];
    const song = (it) =>
      it?.playlistPanelVideoRenderer ||
      it?.playlistPanelVideoWrapperRenderer?.primaryRenderer?.playlistPanelVideoRenderer;
    const currentIndex = () => items().findIndex((it) => song(it)?.selected);
    const click = (sel) => $(sel)?.click();
    const queuePlaylistId = () => new URL(location.href).searchParams.get('list');

    // Finds a queue item's own menu command, e.g. 'removeFromQueueEndpoint'.
    const menuCommand = (s, key) =>
      (s?.menu?.menuRenderer?.items || [])
        .map((i) => (i.menuServiceItemRenderer || i.menuNavigationItemRenderer || {}).serviceEndpoint)
        .find((ep) => ep && ep[key]);

    // Results of async calls (search), collected later with result(id).
    const pending = {};

    function state() {
      const p = player();
      const md = navigator.mediaSession?.metadata;
      let videoId = '';
      try { videoId = p?.getVideoData?.()?.video_id || ''; } catch (e) {}
      const art = md?.artwork?.length
        ? md.artwork[md.artwork.length - 1].src
        : $('ytmusic-player-bar img.image')?.src?.replace(/w\d+-h\d+/, 'w544-h544');
      const byline = $('ytmusic-player-bar .byline')?.textContent || '';
      // The <video> element's clock can span several tracks; the player API and the
      // progress bar report the current track.
      const barMax = Number($('ytmusic-player-bar #progress-bar')?.getAttribute('aria-valuemax')) || 0;
      return {
        videoId: videoId || new URL(location.href).searchParams.get('v') || '',
        title: md?.title || $('ytmusic-player-bar .title')?.textContent?.trim() || '',
        artist: md?.artist || byline.split(' • ')[0].trim(),
        album: md?.album || '',
        artwork: art || null,
        source: queuePlaylistId(),
        playing: p?.getPlayerState?.() === 1,
        position: p?.getCurrentTime?.() || 0,
        duration: barMax || p?.getDuration?.() || 0,
      };
    }

    // The current track and what comes after it. `index` is the position in the full queue.
    function upNext(limit) {
      const all = items();
      const cur = Math.max(currentIndex(), 0);
      return all.slice(cur, cur + limit).map((it, i) => {
        const s = song(it);
        return s && {
          index: cur + i,
          videoId: s.videoId || '',
          title: text(s.title),
          artist: text(s.shortBylineText),
          length: text(s.lengthText),
          thumb: s.thumbnail?.thumbnails?.[0]?.url || null,
          current: !!s.selected,
        };
      }).filter(Boolean);
    }

    function parseSearch(response) {
      const out = [];
      (function walk(node) {
        if (!node || typeof node !== 'object' || out.length >= 30) return;
        const m = node.musicResponsiveListItemRenderer;
        if (m) {
          const col = (i) => m.flexColumns?.[i]?.musicResponsiveListItemFlexColumnRenderer?.text;
          const videoId = m.playlistItemData?.videoId
            || col(0)?.runs?.[0]?.navigationEndpoint?.watchEndpoint?.videoId;
          if (videoId && !out.some((r) => r.videoId === videoId)) {
            const thumbs = m.thumbnail?.musicThumbnailRenderer?.thumbnail?.thumbnails;
            out.push({ videoId, title: text(col(0)), subtitle: text(col(1)), thumb: thumbs?.[0]?.url || null });
          }
          return;
        }
        for (const key in node) walk(node[key]);
      })(response);
      return out;
    }

    return {
      version: 2,
      poll: (withQueue) => ({ state: state(), queue: withQueue ? upNext(100) : null }),
      toggle: () => click('ytmusic-player-bar #play-pause-button'),
      next: () => click('ytmusic-player-bar .next-button'),
      previous: () => click('ytmusic-player-bar .previous-button'),
      seek: (t) => player()?.seekTo?.(t, true),

      search(id, query) {
        pending[id] = null;
        app().networkManager.fetch('/search', { query }).then(
          (res) => { pending[id] = { results: parseSearch(res) }; },
          (err) => { pending[id] = { error: String(err) }; },
        );
      },
      // null while the request is still running.
      result(id) {
        const r = pending[id];
        if (r) delete pending[id];
        return r;
      },

      // position: 'INSERT_AFTER_CURRENT_VIDEO' (play next) | 'INSERT_AT_END' (add to queue)
      add: (videoId, position) => resolve({
        queueAddEndpoint: {
          queueTarget: { videoId, backingQueuePlaylistId: queuePlaylistId(), onEmptyQueue: { watchEndpoint: { videoId } } },
          queueInsertPosition: position,
          commands: [],
        },
      }),
      // Starts the song with its radio, like clicking a search result on the site.
      playNow: (videoId) => resolve({ watchEndpoint: { videoId } }),

      jump(index) {
        const s = song(items()[index]);
        return s?.navigationEndpoint ? resolve(s.navigationEndpoint) : false;
      },
      remove(index) {
        const command = menuCommand(song(items()[index]), 'removeFromQueueEndpoint');
        return command ? resolve(command) : false;
      },
    };
  })();
}
