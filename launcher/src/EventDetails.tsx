import { useEffect, useMemo, useRef, useState } from "react";
import { ANSWER_DECLINE, ANSWER_JOIN, api, kindName, type CharactersView, type Notice } from "./api";
import { Arrow } from "./UI";
import { displayName, isGoing, openEvent, serverWhen } from "./events";

const message = (e: unknown) => (typeof e === "string" ? e : e instanceof Error ? e.message : "Could not send your answer.");

interface Props {
  event: Notice;
  /** The member's characters, from the guild data; the answer buttons need the verified ones. */
  characters: CharactersView | null;
  onClose: () => void;
  /** An answer was saved: refresh the guild's events so the lists show it. */
  onAnswered: () => void;
}

/**
 * The answer buttons: "I'll join" and "I can't attend" for one of the member's own verified
 * characters (main first). It sends the same request as the website, so a character has one answer
 * per event whichever place it came from, and the newest wins. There is no "Maybe".
 */
function Answer({ event, characters, onAnswered }: { event: Notice; characters: CharactersView | null; onAnswered: () => void }) {
  const options = useMemo(() => (characters?.mine ?? [])
    .filter(c => c.status === "verified" && c.id !== event.authorCharacterId)
    .sort((a, b) => Number(!!b.main) - Number(!!a.main)), [characters, event.authorCharacterId]);
  const [choice, setChoice] = useState<number | null>(null);
  const [given, setGiven] = useState<Record<number, string>>(() => Object.fromEntries((event.ownReplies ?? []).filter(r => r.characterId != null).map(r => [r.characterId as number, r.response])));
  const [busy, setBusy] = useState(false);
  const [problem, setProblem] = useState<string | null>(null);
  const [saved, setSaved] = useState<string | null>(null);
  const character = options.find(c => c.id === choice) ?? options[0];
  const answer = character ? given[character.id] : undefined;

  if (!characters) return <p className="set-note">Reading your characters…</p>;
  if (options.length === 0) {
    return <p className="set-note">{characters.mine.some(c => c.id === event.authorCharacterId) ? "You are hosting this event." : "Link and verify a character on the website to answer events."}</p>;
  }
  const send = async (response: string) => {
    if (!character || busy) return;
    setBusy(true); setProblem(null); setSaved(null);
    try {
      const kept = await api.answerEvent(event.scope, event.id, character.id, response);
      setGiven(g => ({ ...g, [character.id]: kept.response }));
      setSaved(`${character.name}: ${kept.response === ANSWER_JOIN ? "you’re going" : "you can’t attend"}.`);
      onAnswered();
    } catch (e) { setProblem(message(e)); } finally { setBusy(false); }
  };
  return (
    <section className="answer-box" aria-label="Your answer">
      {options.length > 1 && (
        <label className="answer-as">Answer as
          <select value={character.id} onChange={e => { setChoice(Number(e.target.value)); setSaved(null); setProblem(null); }}>
            {options.map(c => <option key={c.id} value={c.id}>{c.name}{c.main ? " (main)" : ""}</option>)}
          </select>
        </label>
      )}
      <div className="answer-buttons" role="group" aria-label={`Answer as ${character.name}`}>
        <button className="btn btn-primary" aria-pressed={answer === ANSWER_JOIN} disabled={busy} onClick={() => void send(ANSWER_JOIN)}>{answer === ANSWER_JOIN ? "You’re going" : "I’ll join"}</button>
        <button className="btn" aria-pressed={answer === ANSWER_DECLINE} disabled={busy} onClick={() => void send(ANSWER_DECLINE)}>{answer === ANSWER_DECLINE ? "You can’t attend" : "I can’t attend"}</button>
      </div>
      {options.length === 1 && <p className="set-note">Answering as {character.name}.</p>}
      {saved && <p className="answer-saved" role="status">{saved}</p>}
      {problem && <p className="settings-status is-problem" role="alert">{problem}</p>}
      {!saved && answer === undefined && <p className="set-note">No answer yet.</p>}
    </section>
  );
}

export function EventDetails({ event, characters, onClose, onAnswered }: Props) {
  const dialog = useRef<HTMLDialogElement>(null);
  useEffect(() => { dialog.current?.showModal(); }, []);
  // Only events read from the server carry the answers by character; an event read from the game's
  // saved file can only be answered on the website.
  const fromServer = event.canReply !== undefined;
  const open = event.canReply !== false;
  return <dialog ref={dialog} className="event-dialog" aria-labelledby="event-title" onClose={onClose} onClick={e => { const box = e.currentTarget.getBoundingClientRect(); if (e.target === e.currentTarget && (e.clientX < box.left || e.clientX > box.right || e.clientY < box.top || e.clientY > box.bottom)) onClose(); }}>
    <div className="event-dialog-head"><span className={`eyebrow${event.story ? " story-ribbon" : ""}`}>{kindName(event)}</span><button className="btn btn-small" onClick={onClose}>Close</button></div>
    <h2 id="event-title">{event.title}</h2>
    <p className="event-details-time">{serverWhen(event.start, true)}</p>
    {event.location && <p>{event.location}</p>}
    <p className="set-note">Posted by {event.authorName || displayName(event.author)}</p>
    <div className="event-full-text">{event.body}</div>
    {fromServer && open
      ? <Answer event={event} characters={characters} onAnswered={onAnswered} />
      : <p className={isGoing(event) ? "going-mark" : "set-note"}>{open ? "Answer this event on the website." : "This event has ended."}</p>}
    <button className="btn btn-small answer-site" onClick={() => openEvent(event)}>Open on the website <Arrow external /></button>
  </dialog>;
}
