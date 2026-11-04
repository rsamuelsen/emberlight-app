export function Arrow({ external = false }: { external?: boolean }) {
  return <svg className="row-arrow" viewBox="0 0 20 20" aria-hidden="true"><path d={external ? "M8 4h8v8M16 4 7 13M12 16H4V8" : "m8 5 5 5-5 5"} /></svg>;
}

/** The same quiet treatment for empty, loading and unavailable content. */
export function EmptyState({ title, detail, problem = false }: { title: string; detail?: string; problem?: boolean }) {
  return (
    <div className={`empty-state${problem ? " is-problem" : ""}`} role={problem ? "alert" : "status"}>
      <p className="empty-title">{title}</p>
      {detail && <p className="empty-detail">{detail}</p>}
    </div>
  );
}
