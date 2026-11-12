// Music sources. Everything that finds songs goes through the active source, so a second source can be added in one place.
//
// A source is a plain object:
//   id, name                          short id and the name shown in the app
//   search(query, { filter, limit })  -> Track[]            filter is "songs" or "videos"
//   suggest(query)                    -> string[]           search-as-you-type suggestions
//   audio(id, use, opts)              -> { url, blob, size }  where to play a song from (see getAudio in api.js)
// A Track is { videoId, title, artists[], album?, thumbnail, duration }. `videoId` is the source's own id for the song.
//
// Only sources that ship inside the app are registered. There is deliberately no way to load code from a URL or a file:
// that code would run next to your library and account, so a new source is a reviewed change to this repository.
import { api, getAudio } from "./api.js";

const youtube = {
  id: "youtube",
  name: "YouTube Music",
  search: (q, { filter = "songs", limit } = {}) => api(`/api/search?q=${encodeURIComponent(q)}&filter=${filter}${limit ? `&limit=${limit}` : ""}`),
  suggest: (q) => api(`/api/suggest?q=${encodeURIComponent(q)}`),
  audio: (id, use, opts) => getAudio(id, use, opts),
};

const registry = new Map([[youtube.id, youtube]]);
const REQUIRED = ["id", "name", "search", "audio"];

/** Adds a built-in source. Throws if it is missing a required part, so a mistake shows up when the app starts. */
export function register(src) {
  const bad = REQUIRED.filter((k) => !src?.[k]);
  if (bad.length) throw new Error(`source is missing: ${bad.join(", ")}`);
  registry.set(src.id, src);
}
export const all = () => [...registry.values()];
export const get = (id) => registry.get(id);
/** The source in use. Today that is always YouTube Music; a source picker would change only this function. */
export const active = () => youtube;
