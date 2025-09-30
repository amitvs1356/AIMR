import { useRouter } from "next/router";
import useSWR from "swr";
const f=(u:string)=>fetch(u).then(r=>r.json());
export default function Movie(){
  const {query}=useRouter();
  const {data}=useSWR(query.id?`/api/movies?limit=1&offset=0&id=${query.id}`:null,f);
  const m = Array.isArray(data)&&data.length?data[0]:null;
  return <main style={{maxWidth:720,margin:"40px auto",padding:"0 16px",fontFamily:"system-ui"}}>
    <a href="/">← Back</a>
    <h1>{m?.title||"Movie"}</h1>
    <pre style={{whiteSpace:"pre-wrap"}}>{JSON.stringify(m,null,2)}</pre>
  </main>;
}
