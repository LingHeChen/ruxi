// Copy to lib/main.dart in a Flutter project. Layout/gesture probe only; no video plugin.
import 'package:flutter/material.dart';
void main() => runApp(const MaterialApp(home: Probe()));
class Probe extends StatefulWidget { const Probe({super.key}); @override State<Probe> createState()=>_ProbeState(); }
class _ProbeState extends State<Probe> {
 final draft=TextEditingController(); final focus=FocusNode();
 final stageKey=GlobalKey(); double extent=.45; int requests=0; bool reduced=false;
 @override void dispose(){draft.dispose();focus.dispose();super.dispose();}
 @override Widget build(BuildContext context){
  final reduce=reduced||MediaQuery.of(context).disableAnimations;
  return Scaffold(appBar:AppBar(title:const Text('入戏 布局与面板实验')),body:LayoutBuilder(builder:(context,c){
   final wide=c.maxWidth>=850;
   final stage=Container(key:stageKey,color:const Color(0xff29493b),child:const Center(child:Text('稳定舞台宿主\n此样例未接入视频播放器',textAlign:TextAlign.center,style:TextStyle(color:Colors.white))));
   final panel=Material(color:const Color(0xfff5f3ef),child:SingleChildScrollView(child:Padding(padding:const EdgeInsets.all(20),child:Column(children:[
    GestureDetector(onVerticalDragUpdate:(d){setState(()=>extent=(extent-d.delta.dy/c.maxHeight).clamp(.25,.8));},onVerticalDragEnd:(d){setState(()=>extent=d.primaryVelocity!=null&&d.primaryVelocity!.abs()>800?(d.primaryVelocity!<0?.8:.25):[.25,.5,.8].reduce((a,b)=>(a-extent).abs()<(b-extent).abs()?a:b));},child:const SizedBox(height:48,width:double.infinity,child:Center(child:Icon(Icons.drag_handle)))),
    const Text('输入草稿后改变窗口尺寸，检查内容、焦点与提交次数。'),
    TextField(controller:draft,focusNode:focus,decoration:const InputDecoration(labelText:'其他行动')),
    SwitchListTile(title:const Text('减少动态'),value:reduced,onChanged:(v)=>setState(()=>reduced=v)),
    FilledButton(onPressed:()=>setState(()=>requests++),child:Text('模拟提交 $requests 次')),
   ]))));
   // Stack child order stays stable when switching layout. No command in animation callbacks.
   return Stack(children:[Positioned(left:0,top:0,right:wide?360:0,bottom:wide?0:c.maxHeight*extent,child:stage),
    AnimatedPositioned(duration:reduce?Duration.zero:const Duration(milliseconds:240),curve:Curves.easeOutCubic,
     right:0,bottom:0,width:wide?360:c.maxWidth,height:wide?c.maxHeight:c.maxHeight*extent,child:panel)]);
  }));
 }
}
