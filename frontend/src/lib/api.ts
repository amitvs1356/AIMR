export async function fetchJSON<T=any>(path: string) {
  const res = await fetch(`/api${path}`, { next: { revalidate: 60 }});
  if (!res.ok) throw new Error(`API ${path} -> ${res.status}`);
  return res.json() as Promise<T>;
}
