import { useEffect, useRef } from "react";
import type { Notice } from "./api";
import { Arrow } from "./UI";
import { displayName, isGoing, openEvent, serverWhen } from "./events";

export function EventDetails({ event, onClose }: { event: Notice; onClose: () => void }) {
  const dialog = useRef<HTMLDialogElement>(null);
  useEffect(() => { dialog.current?.showModal(); }, []);
  return <dialog ref={dialog} className="event-dialog" aria-labelledby="event-title" onClose={onClose} onClick={e => { const box = e.currentTarget.getBoundingClientRect(); if (e.target === e.currentTarget && (e.clientX < box.left || e.clientX > box.right || e.clientY < box.top || e.clientY > box.bottom)) onClose(); }}>
    <div className="event-dialog-head"><span className="eyebrow">{event.category === 4 ? "Guild event" : "Adventure"}</span><button className="btn btn-small" onClick={onClose}>Close</button></div>
    <h2 id="event-title">{event.title}</h2>
    <p className="event-details-time">{serverWhen(event.start, true)}</p>
    {event.location && <p>{event.location}</p>}
    <p className="set-note">Posted by {event.authorName || displayName(event.author)}</p>
    <div className="event-full-text">{event.body}</div>
    <p className={isGoing(event) ? "going-mark" : "set-note"}>Your answer: {event.ownReplies?.length ? [...new Set(event.ownReplies.map(r => r.response))].join(", ") : event.ownReplies ? "No answer yet" : "Check on the website"}</p>
    <button className="btn btn-primary" onClick={() => openEvent(event)}>Answer on the website <Arrow external /></button>
  </dialog>;
}
