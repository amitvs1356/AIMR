import useSWR from "swr";
const fetcher = (url:string)=>fetch(url).then(r=>r.json());
export default function Home(){
  const {data}=useSWR("/api/movies?limit=12", fetcher);
  return (
    <main style={{maxWidth:960,margin:"40px auto",padding:"0 16px",fontFamily:"system-ui"}}>
      <h1>AI Movie Review — Home</h1>
      <div style={{display:"grid",gridTemplateColumns:"repeat(auto-fill, minmax(180px, 1fr))",gap:16}}>
        {(data||[]).map((m:any)=>(
          <a key={m.id} href={`/movies/${m.id}`} style={{textDecoration:"none",color:"inherit",border:"1px solid #eee",borderRadius:12,padding:12}}>
            <div style={{fontWeight:600}}>{m.title}</div>
            <div style={{opacity:.7,fontSize:12}}>{m.release_date||""}</div>
          </a>
        ))}
      </div>
    </main>
  );
}
