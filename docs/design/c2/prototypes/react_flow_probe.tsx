// Embed in a React project with @xyflow/react. Not a production studio.
import {useCallback, useMemo, useState} from 'react';
import {ReactFlow,Background,Controls,applyNodeChanges,Node,Edge,NodeChange} from '@xyflow/react';
import '@xyflow/react/dist/style.css';
const initial=[{id:'dining',label:'餐厅',x:0},{id:'hall',label:'走廊',x:300},{id:'kitchen',label:'后厨',x:600}];
export default function WorldProbe(){
 const [cost,setCost]=useState(1); const [selected,setSelected]=useState('inspect');
 const [nodes,setNodes]=useState<Node[]>([...initial.map(l=>({id:l.id,position:{x:l.x,y:0},data:{label:l.label},style:{width:250,height:180}})),
 {id:'inspect',parentId:'dining',extent:'parent',position:{x:25,y:70},data:{label:'检查餐具 · 1点'}}]);
 const shown=useMemo(()=>nodes.map(n=>n.id==='inspect'?{...n,data:{label:`检查餐具 · ${cost}点`}}:n),[nodes,cost]);
 const edges:Edge[]=[{id:'d_h',source:'dining',target:'hall',label:'通路 1点'},{id:'h_k',source:'hall',target:'kitchen',label:'需要开门'}];
 const onNodesChange=useCallback((changes:NodeChange[])=>setNodes(ns=>applyNodeChanges(changes,ns)),[]);
 return <main style={{height:600,display:'grid',gridTemplateColumns:'1fr 280px'}}><ReactFlow nodes={shown} edges={edges} onNodesChange={onNodesChange} onNodeClick={(_,n)=>setSelected(n.id)} fitView><Background/><Controls/></ReactFlow><aside><h2>同一实体的属性</h2><p>{selected}</p><label>检查餐具成本<input type="number" min={0} max={10} value={cost} onChange={e=>setCost(Math.max(0,Math.min(10,Number(e.target.value))))}/></label><p>修改成本即时反映节点；拖动只影响布局。</p><button onClick={()=>localStorage.setItem('probe_layout',JSON.stringify(nodes.map(n=>({id:n.id,position:n.position,parentId:n.parentId}))))}>保存布局实验</button><p>未接后端、Schema验证与多人协作。</p></aside></main>;
}
