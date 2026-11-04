import type { UpdateProgress } from "./api";
export function UpdateProgressView({ progress }: { progress: UpdateProgress | null }) {
  if (!progress || progress.stage === "failed") return null;
  const total = progress.total && progress.total > 0 ? progress.total : undefined;
  const percent = total ? Math.min(100, Math.floor((progress.downloaded ?? 0) / total * 100)) : undefined;
  return <div className="update-progress" role="status"><p>{progress.stage === "installing" ? "Installing" : percent !== undefined ? `Downloading update · ${percent}%` : "Downloading update"}</p>
    {progress.stage !== "installing" && <progress aria-label="Companion update download" max={100} value={percent} />}</div>;
}
