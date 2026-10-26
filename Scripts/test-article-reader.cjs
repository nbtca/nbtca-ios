// Run with NODE_PATH pointing to a temporary installation of jsdom@26.1.0.
const {test} = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const {JSDOM} = require('jsdom');
const assets = path.resolve(__dirname,'../nbtca/Resources/ArticleReader');
const scripts = ['markdown-it.min.js','purify.min.js','article-reader.js'].map(name=>fs.readFileSync(path.join(assets,name),'utf8'));
function render(overrides={}) {
  const dom = new JSDOM('<main id="reader"></main>',{runScripts:'outside-only',url:'https://nbtca.space/'});
  scripts.forEach(script=>dom.window.eval(script));
  const messages=[];
  dom.window.webkit={messageHandlers:{articleLink:{postMessage:url=>messages.push(url)}}};
  const data = {title:'测试文章',category:'技术',author:'作者',published:'2026 年 10 月 21 日',tags:['技术'],
    cover:'',url:'https://nbtca.space/posts/test/',summary:'摘要内容',markdown:'正文',originalHTML:'',...overrides};
  dom.window.ArticleReader.render(data);
  return {dom,document:dom.window.document,messages};
}
test('original prose preserves separate div paragraphs, tables and exact code whitespace',()=>{
  const html='<nav>导航</nav><article class="article"><div class="article-header"><h1>重复标题</h1></div><div class="prose"><div class="page-body-copy">第一段</div><div class="page-body-copy">第二段</div><table><thead><tr><th>甲</th><th>乙</th></tr></thead><tbody><tr><td>1</td><td>2</td></tr></tbody></table><pre><code>one\n\n  two\n</code></pre></div><div class="article-copyright">原署名</div></article>';
  const {document:d}=render({originalHTML:html});
  assert.equal(d.querySelectorAll('.page-body-copy').length,2);
  assert.equal(d.querySelectorAll('.table-scroll table td').length,2);
  assert.equal(d.querySelector('pre').textContent,'one\n\n  two\n');
  assert.equal(d.querySelectorAll('h1').length,1);
  assert.equal(d.querySelector('.article-copyright').textContent,'原署名');
  assert(!d.body.textContent.includes('导航'));
});
test('missing original container falls back to Markdown without displaying a login/error page',()=>{
  const {document:d}=render({originalHTML:'<main><h1>服务器错误</h1></main>',markdown:'## 正文标题\n\n正文内容'});
  assert.equal(d.querySelector('#article-body h2').textContent,'正文标题');
  assert(!d.body.textContent.includes('服务器错误'));
});
test('code fences retain blank lines and literal Markdown syntax',()=>{
  const code='## literal\n\n**not bold**\n```inside\n';
  const {document:d}=render({markdown:'````go\n'+code+'````\n\n下一段'});
  assert.equal(d.querySelector('pre code').textContent,code);
  assert.equal(d.querySelector('pre code').className,'language-go');
  assert.equal(d.querySelectorAll('pre strong').length,0);
});
test('Markdown renders nested lists, quotes, rules, inline formatting and tables with alignment',()=>{
  const {document:d}=render({markdown:'## 标题\n\n1. 第一项\n   - 嵌套\n\n> 引用 **加粗**\n\n---\n\n~~删除~~ `代码`\n\n| 左 | 右 |\n| :-- | --: |\n| 甲 | 乙 |'});
  assert.equal(d.querySelector('ol ul li').textContent,'嵌套');
  assert.equal(d.querySelector('blockquote strong').textContent,'加粗');
  assert.equal(d.querySelectorAll('hr').length,1);
  assert.equal(d.querySelector('s').textContent,'删除');
  assert.equal(d.querySelector('td:last-child').style.textAlign,'right');
});
test('task list checkboxes retain status and cannot be edited',()=>{
  const {document:d}=render({markdown:'- [ ] 待办\n- [x] 完成'});
  const boxes=d.querySelectorAll('input[type=checkbox]');
  assert.equal(boxes.length,2); assert(!boxes[0].checked); assert(boxes[1].checked);
  assert([...boxes].every(box=>box.disabled));
});
test('inline images and relative links resolve against the article, image dimensions are not fixed',()=>{
  const {document:d}=render({markdown:'前文 ![图片说明](../figure.png) 后文\n\n[相对链接](../other/)'});
  const img=d.querySelector('#article-body img');
  assert.equal(img.src,'https://nbtca.space/posts/figure.png');
  assert.equal(img.alt,'图片说明'); assert(!img.hasAttribute('height'));
  assert.equal(d.querySelector('#article-body a').href,'https://nbtca.space/posts/other/');
});
test('source image width, page CSS and scripts cannot change reader layout or execute',()=>{
  const {document:d,dom}=render({originalHTML:'<article class="article"><div class="prose"><style>body{width:9999px}</style><script>window.injected=1</script><img src="/picture.png" width="2000" height="500" style="position:fixed;width:2000px" onerror="window.injected=2"><iframe src="https://example.com"></iframe><p><a href="javascript:alert(1)">危险链接</a></p></div></article>'});
  assert.equal(d.querySelectorAll('script,style,iframe').length,0);
  const img=d.querySelector('img');
  assert(!img.hasAttribute('style')); assert(!img.hasAttribute('onerror')); assert(!img.hasAttribute('width')); assert(!img.hasAttribute('height'));
  assert(!d.querySelector('#article-body a').hasAttribute('href')); assert.equal(dom.window.injected,undefined);
});
test('source Shiki colours are retained for both light and dark mode',()=>{
  const {document:d,dom}=render({originalHTML:'<article class="article"><div class="prose"><pre><code><span style="color:#24292e;--shiki-dark:#e1e4e8;position:fixed">const</span></code></pre></div></article>'});
  const token=d.querySelector('pre span'); assert(token.style.color); assert.equal(token.style.getPropertyValue('--shiki-dark'),'#e1e4e8'); assert(!token.style.position);
  dom.window.ArticleReader.appearance(23,true); assert.equal(d.documentElement.dataset.theme,'dark'); assert.equal(d.documentElement.style.fontSize,'23px');
});
test('same-article TOC links scroll internally, external links go to the native handler',()=>{
  const {document:d,dom,messages}=render({markdown:'[目录](#章节)\n\n## 章节\n\n[外链](https://example.com/path)'});
  let scrolled=false; d.getElementById('章节').scrollIntoView=()=>{scrolled=true;};
  const links=d.querySelectorAll('#article-body a');
  links[0].dispatchEvent(new dom.window.MouseEvent('click',{bubbles:true,cancelable:true}));
  assert(scrolled); assert.equal(messages.length,0);
  links[1].dispatchEvent(new dom.window.MouseEvent('click',{bubbles:true,cancelable:true}));
  assert.deepEqual(messages,['https://example.com/path']);
});
test('BFF header and summary appear once while identical later body headings remain',()=>{
  const {document:d}=render({markdown:'技术 2026 年 10 月 21 日\n\n# 测试文章\n\n摘要内容[ 技术 ](https://nbtca.space/tags/技术)正文开始\n\n## 测试文章\n\n保留正文'});
  assert.equal(d.querySelectorAll('.article-summary').length,1);
  assert(!d.querySelector('#article-body').textContent.includes('摘要内容'));
  assert(d.querySelector('#article-body').textContent.includes('正文开始'));
  assert.equal(d.querySelector('#article-body h2').textContent,'测试文章');
});
test('metadata is text, never executable HTML',()=>{
  const {document:d}=render({title:'<img src=x onerror=alert(1)>',summary:'<script>alert(1)</script>',tags:['<svg onload=alert(1)>']});
  assert.equal(d.querySelectorAll('script,svg,img').length,0);
  assert.equal(d.querySelector('h1').textContent,'<img src=x onerror=alert(1)>');
});
test('duplicate heading IDs remain unique in Markdown fallback',()=>{
  const {document:d}=render({markdown:'## 同名\n\n## 同名\n\n## 另一节'});
  const ids=[...d.querySelectorAll('#article-body h2')].map(h=>h.id);
  assert.equal(new Set(ids).size,3);
});
test('a body without a summary is still rendered when the original is unavailable',()=>{
  const {document:d}=render({summary:'',originalHTML:'',markdown:'正文 **保留**'});
  assert.equal(d.querySelector('#article-body strong').textContent,'保留');
});
test('real downloaded reference article retains its original semantic structure when provided',()=>{
  const source=process.env.NBTCA_REFERENCE_ARTICLE;
  if (!source) return;
  const html=fs.readFileSync(source,'utf8');
  const {document:d}=render({originalHTML:html});
  assert.equal(d.querySelectorAll('#article-body table').length,1);
  assert.equal(d.querySelectorAll('#article-body td').length,10);
  assert.equal(d.querySelectorAll('#article-body pre').length,7);
  assert.equal(d.querySelectorAll('.article-title').length,1);
  assert(d.querySelectorAll('.page-body-copy').length>20);
});
