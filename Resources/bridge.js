// Runs inside YouTube Music's page (main world), where its player, queue store and
// command system live. PlayerBridge sends this file with every call; the version guard
// keeps a single instance per page load.
//
// Queue changes use YouTube Music's own code paths: its commands, its queue menu, and its
// queue store actions.
if (!window.__ytp || window.__ytp.version !== 12) {
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

    // Results of async calls, collected later with result(id): { value } or { error }.
    const pending = {};
    const settle = (id, promise) => {
      pending[id] = null;
      promise.then(
        (value) => { pending[id] = { value }; },
        (error) => { pending[id] = { error: String(error) }; },
      );
    };

    const likeButtons = () => $('ytmusic-player-bar ytmusic-like-button-renderer');

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
        liked: likeButtons()?.getAttribute('like-status') === 'LIKE',
        position: p?.getCurrentTime?.() || 0,
        duration: barMax || p?.getDuration?.() || 0,
      };
    }

    // The current track and what comes after it. `index` is the position in the full queue.
    const automix = () => $('#queue')?.queue?.store?.store?.getState().queue.automixItems || [];

    function describe(it, index, autoplay) {
      const s = song(it);
      return s && {
        index,
        videoId: s.videoId || '',
        title: text(s.title),
        artist: text(s.shortBylineText),
        length: text(s.lengthText),
        thumb: s.thumbnail?.thumbnails?.[0]?.url || null,
        current: !!s.selected,
        autoplay,
      };
    }

    function upNext(limit) {
      const cur = Math.max(currentIndex(), 0);
      return items().slice(cur, cur + limit).map((it, i) => describe(it, cur + i, false)).filter(Boolean);
    }

    // What plays after the queue runs out (YouTube Music's "Autoplay" section).
    // `index` is the position in that separate list.
    function autoplay(limit) {
      return automix().slice(0, limit).map((it, i) => describe(it, i, true)).filter(Boolean);
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

    // A song's queue entry, from /next: the request YouTube Music fills Up Next with.
    async function queueEntry(videoId) {
      const res = await app().networkManager.fetch('/next', { videoId, isAudioOnly: true });
      let entry = null;
      (function walk(node) {
        if (!node || typeof node !== 'object' || entry) return;
        if ((node.playlistPanelVideoRenderer || node.playlistPanelVideoWrapperRenderer) && song(node)?.videoId === videoId) {
          entry = node;
          return;
        }
        for (const key in node) walk(node[key]);
      })(res);
      if (!entry) return null;
      // /next marks the requested song as the one playing. Inserted with that flag, YouTube
      // Music treats it as a second current song and overwrites it with the real one.
      const copy = structuredClone(entry);
      (function unselect(node) {
        if (!node || typeof node !== 'object') return;
        if ('selected' in node) node.selected = false;
        for (const key in node) unselect(node[key]);
      })(copy);
      return copy;
    }

    // Inserts songs into the page's queue, which is what plays next. YouTube Music's own
    // "Add to queue" command gets no song back for server-side queues, so it adds nothing.
    async function addToQueue(videoIds, next) {
      const entries = (await Promise.all(videoIds.map(queueEntry))).filter(Boolean);
      if (!entries.length) throw new Error('Song not found on YouTube Music');
      const queue = $('#queue');
      const st = queue.queue.store.store.getState().queue;
      const cur = currentIndex();
      queue.dispatch({
        type: 'ADD_ITEMS',
        payload: {
          nextQueueItemId: st.nextQueueItemId,
          index: next && cur >= 0 ? cur + 1 : st.items.length,
          items: entries,
          shuffleEnabled: false,
          shouldAssignIds: true,
        },
      });
      return entries.length;
    }

    // Equalizer: the page's <video> → preamp → 10 filters → limiter → speakers.
    // Kept on window.__ytpEq rather than in this closure: an element can only be wired to
    // Web Audio once per page load, and this script is replaced when its version changes.
    const EQ_BANDS = [31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000];
    const EQ_CHAIN_VERSION = 1;

    function eqGraph() {
      const video = $('video');
      if (!video) return null;
      let g = window.__ytpEq;
      if (!g || g.video !== video) {
        const ctx = g?.ctx || new AudioContext({ latencyHint: 'playback' });
        g = window.__ytpEq = { ctx, video, source: ctx.createMediaElementSource(video) };
      }
      if (g.chainVersion !== EQ_CHAIN_VERSION) {
        const { ctx } = g;
        g.source.disconnect();
        g.preamp = ctx.createGain();
        g.filters = EQ_BANDS.map((frequency, i) => {
          const filter = ctx.createBiquadFilter();
          // Shelves at the ends so the lowest and highest bands cover everything beyond them.
          filter.type = i === 0 ? 'lowshelf' : i === EQ_BANDS.length - 1 ? 'highshelf' : 'peaking';
          filter.frequency.value = frequency;
          filter.Q.value = 1.4;  // about one octave wide, so neighbouring bands blend smoothly
          return filter;
        });
        // Brick-wall limiter just under 0 dBFS, so boosts can't clip.
        g.limiter = ctx.createDynamicsCompressor();
        g.limiter.knee.value = 0;
        g.limiter.attack.value = 0.003;
        g.limiter.release.value = 0.25;
        let node = g.source;
        for (const next of [g.preamp, ...g.filters, g.limiter]) { node.connect(next); node = next; }
        g.limiter.connect(ctx.destination);
        g.chainVersion = EQ_CHAIN_VERSION;
        g.key = null;
      }
      return g;
    }

    // cfg: { on, preamp: dB, gains: [10 × dB] }. The page's audio isn't touched until the
    // EQ is first switched on; after that, "off" sets everything to neutral.
    function setEq(cfg) {
      if (!cfg || (!cfg.on && !window.__ytpEq)) return 'off';
      const key = JSON.stringify(cfg);
      const g = eqGraph();
      if (!g) return 'no audio';
      if (g.key !== key) {
        const t = g.ctx.currentTime;
        g.preamp.gain.setTargetAtTime(cfg.on ? 10 ** (cfg.preamp / 20) : 1, t, 0.03);
        g.filters.forEach((f, i) => f.gain.setTargetAtTime(cfg.on ? cfg.gains[i] || 0 : 0, t, 0.03));
        g.limiter.threshold.value = cfg.on ? -1 : 0;
        g.limiter.ratio.value = cfg.on ? 20 : 1;  // ratio 1 passes audio unchanged
        g.key = key;
      }
      if (g.ctx.state === 'suspended') g.ctx.resume();
      return g.ctx.state;
    }

    const trySetEq = (cfg) => {
      try { return setEq(cfg); } catch (e) { return 'error: ' + e.message; }
    };

    // ---- Library: playlists and Liked Music ----

    const browse = (body) => app().networkManager.fetch('/browse', body);
    const shuffles = {};  // playlistId → the playlist's own Shuffle endpoint

    // Walks a response for playlist tracks; returns the next page's continuation token.
    function collectTracks(response, out) {
      let token = null;
      (function walk(node) {
        if (!node || typeof node !== 'object') return;
        const m = node.musicResponsiveListItemRenderer;
        if (m) {
          const col = (i) => m.flexColumns?.[i]?.musicResponsiveListItemFlexColumnRenderer?.text;
          const data = m.playlistItemData || {};
          const watch = m.overlay?.musicItemThumbnailOverlayRenderer?.content?.musicPlayButtonRenderer
            ?.playNavigationEndpoint?.watchEndpoint;
          if (data.videoId) {
            out.push({
              videoId: data.videoId,
              setVideoId: data.playlistSetVideoId || null,
              title: text(col(0)),
              artist: text(col(1)),
              length: text(m.fixedColumns?.[0]?.musicResponsiveListItemFixedColumnRenderer?.text),
              thumb: m.thumbnail?.musicThumbnailRenderer?.thumbnail?.thumbnails?.[0]?.url || null,
              // ATV song, OMV / OFFICIAL_SOURCE_MUSIC / UGC music video, PODCAST_EPISODE; null = plain video
              type: watch?.watchEndpointMusicSupportedConfigs?.watchEndpointMusicConfig?.musicVideoType || null,
            });
          }
          return;
        }
        if (node.continuationCommand && !token) token = node.continuationCommand.token;
        for (const key in node) walk(node[key]);
      })(response);
      return token;
    }

    // Every playlist in the library, except podcast episodes ("Episodes for Later").
    async function libraryPlaylists() {
      const out = [];
      let response = await browse({ browseId: 'FEmusic_liked_playlists' });
      for (let page = 0; response && page < 10; page++) {
        let token = null;
        (function walk(node) {
          if (!node || typeof node !== 'object') return;
          const m = node.musicTwoRowItemRenderer;
          if (m) {
            const browseId = m.navigationEndpoint?.browseEndpoint?.browseId || '';
            const thumbs = m.thumbnailRenderer?.musicThumbnailRenderer?.thumbnail?.thumbnails;
            if (browseId.startsWith('VL') && browseId !== 'VLSE') {
              out.push({ id: browseId.slice(2), title: text(m.title), subtitle: text(m.subtitle),
                         thumb: thumbs?.[thumbs.length - 1]?.url || null });
            }
            return;
          }
          if (node.continuationCommand && !token) token = node.continuationCommand.token;
          for (const key in node) walk(node[key]);
        })(response);
        response = token ? await browse({ continuation: token }) : null;
      }
      return out;
    }

    // All tracks of a playlist, following pages of 100 (up to 5000 tracks).
    async function playlistTracks(playlistId) {
      const tracks = [];
      let response = await browse({ browseId: 'VL' + playlistId });
      (function findShuffle(node) {
        if (!node || typeof node !== 'object' || shuffles[playlistId]) return;
        if (node.watchPlaylistEndpoint?.params) { shuffles[playlistId] = node.watchPlaylistEndpoint; return; }
        for (const key in node) findShuffle(node[key]);
      })(response);
      let token = collectTracks(response, tracks);
      for (let page = 0; token && page < 50; page++) {
        token = collectTracks(await browse({ continuation: token }), tracks);
      }
      return tracks;
    }

    // Same request YouTube Music's playlist menus make. Resolves to the edit results.
    async function editPlaylist(playlistId, actions) {
      const res = await app().networkManager.fetch('/browse/edit_playlist', { playlistId, actions });
      if (res?.status !== 'STATUS_SUCCEEDED') throw new Error('YouTube Music refused the change');
      return (res.playlistEditResults || []).map((r) => r.playlistEditVideoAddedResultData?.setVideoId || null);
    }

    return {
      version: 12,
      poll: (withQueue, eq) => ({
        eq: trySetEq(eq),
        state: state(),
        queue: withQueue ? upNext(100) : null,
        autoplay: withQueue ? autoplay(50) : null,
      }),
      setEq: trySetEq,
      toggle: () => click('ytmusic-player-bar #play-pause-button'),
      toggleLike: () => (likeButtons()?.querySelector('#button-shape-like button') || likeButtons()?.querySelector('button'))?.click(),
      next: () => click('ytmusic-player-bar .next-button'),
      previous: () => click('ytmusic-player-bar .previous-button'),
      seek: (t) => player()?.seekTo?.(t, true),

      search: (id, query) => settle(id, app().networkManager.fetch('/search', { query }).then(parseSearch)),
      library: (id) => settle(id, libraryPlaylists()),
      playlistTracks: (id, playlistId) => settle(id, playlistTracks(playlistId)),
      // Resolves to the new songs' setVideoIds (needed to remove them later).
      addToPlaylist: (id, playlistId, videoIds) => settle(id, editPlaylist(playlistId,
        videoIds.map((addedVideoId) => ({ action: 'ACTION_ADD_VIDEO', addedVideoId, dedupeOption: 'DEDUPE_OPTION_SKIP' })))),
      removeFromPlaylist: (id, playlistId, videoId, setVideoId) => settle(id, editPlaylist(playlistId,
        [{ action: 'ACTION_REMOVE_VIDEO', removedVideoId: videoId, setVideoId }])),
      createPlaylist: (id, title) => settle(id, app().networkManager
        .fetch('/playlist/create', { title, privacyStatus: 'PRIVATE', videoIds: [] })
        .then((res) => {
          if (!res?.playlistId) throw new Error('YouTube Music did not create the playlist');
          return res.playlistId;
        })),
      setLike: (id, videoId, liked) => settle(id, app().networkManager
        .fetch(liked ? '/like/like' : '/like/removelike', { target: { videoId } }).then(() => true)),
      playPlaylist: (playlistId, shuffle) => resolve(shuffle
        ? { watchPlaylistEndpoint: shuffles[playlistId] || { playlistId, params: 'wAEB' } }
        : { watchEndpoint: { playlistId } }),
      playFromPlaylist: (playlistId, videoId) => resolve({ watchEndpoint: { videoId, playlistId } }),
      // null while the request is still running.
      result(id) {
        const r = pending[id];
        if (r) delete pending[id];
        return r;
      },

      // Adds songs after the current one (next = true) or at the end. Resolves to the count added.
      add: (id, videoIds, next) => settle(id, addToQueue(videoIds, next)),
      // Starts the song with its radio, like clicking a search result on the site.
      playNow: (videoId) => resolve({ watchEndpoint: { videoId } }),

      jump(index) {
        const s = song(items()[index]);
        return s?.navigationEndpoint ? resolve(s.navigationEndpoint) : false;
      },
      playAutoplay(index, videoId) {
        const s = song(automix()[index]);
        return s?.videoId === videoId && s.navigationEndpoint ? resolve(s.navigationEndpoint) : false;
      },
      // Does what YouTube Music's queue service removeItem does internally: tell the
      // server-side queue, then update the local one. Calling removeItem itself doesn't
      // find the item, and the ⋮ menu route needs the page on screen to open its popup.
      remove(index, videoId) {
        const queue = $('#queue')?.polymerController?.queue;
        const all = queue?.getItems() || [];
        if (song(all[index])?.videoId !== videoId) return false;
        const serverKey = Object.getOwnPropertyNames(queue).find((k) => /_serverQueueApi$/.test(k));
        queue[serverKey]?.removeItem(all[index]);
        queue.store.dispatch({ type: 'REMOVE_ITEM', payload: index });
        return true;
      },
      // `to` is the song's final position.
      move(from, to, videoId) {
        const all = items();
        if (song(all[from])?.videoId !== videoId || to < 0 || to >= all.length) return false;
        $('#queue').dispatch({ type: 'MOVE_ITEM', payload: { fromIndex: from, toIndex: to } });
        return true;
      },
    };
  })();
}
