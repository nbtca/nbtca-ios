/* Local article renderer. Dependencies and licenses are bundled with the app. */
(() => {
  'use strict';
  const md = window.markdownit({ html:false, linkify:true, typographer:false });
  md.core.ruler.after('inline','task-lists',state => {
    state.tokens.forEach((token,index) => {
      if (token.type!=='inline' || state.tokens[index-1]?.type!=='paragraph_open' || state.tokens[index-2]?.type!=='list_item_open') return;
      const first=token.children?.[0], match=first?.type==='text' && /^\[([ xX])\] /.exec(first.content);
      if (!match) return;
      first.content=first.content.slice(4);
      const checkbox=new state.Token('html_inline','',0);
      checkbox.content='<input type="checkbox" disabled'+(match[1].toLowerCase()==='x'?' checked':'')+'>';
      token.children.unshift(checkbox); state.tokens[index-2].attrSet('class','task-list-item');
    });
  });
  const safeURL = (value, base, image = false) => {
    if (typeof value !== 'string' || !value.trim()) return null;
    try {
      const url = new URL(value, base || 'https://nbtca.space/');
      if (['https:', 'http:'].includes(url.protocol)) return url.href;
      if (!image && ['mailto:', 'tel:'].includes(url.protocol)) return url.href;
      if (image && /^data:image\/(png|jpeg|gif|webp|avif);base64,/i.test(value)) return value;
    } catch (_) {}
    return null;
  };
  function clean(html, base) {
    const fragment = DOMPurify.sanitize(html, {
      USE_PROFILES:{html:true, mathMl:true}, RETURN_DOM_FRAGMENT:true,
      FORBID_TAGS:['style','form','button','textarea','select','video','audio','source','iframe','object','embed'],
      FORBID_ATTR:['srcset','sizes','autofocus','formaction','action','background'],
      ALLOW_DATA_ATTR:false
    });
    fragment.querySelectorAll('*').forEach(node => {
      // Keep Shiki token colours, never page-level layout or arbitrary CSS.
      const style = node.style;
      if (style) {
        const colors = ['color','--shiki-dark'].map(key => [key, style.getPropertyValue(key)]);
        const alignment=style.textAlign;
        node.removeAttribute('style');
        if (node.closest('pre')) colors.forEach(([key,value]) => {
          if (/^(#[\da-f]{3,8}|rgba?\([\d.,%\s]+\)|[a-z]+)$/i.test(value)) node.style.setProperty(key,value);
        });
        if (['TD','TH'].includes(node.tagName) && ['left','center','right'].includes(alignment)) node.style.textAlign=alignment;
      }
      if (node.hasAttribute('href')) {
        const url = safeURL(node.getAttribute('href'), base);
        if (url) { node.setAttribute('href',url); node.setAttribute('rel','noopener noreferrer'); }
        else node.removeAttribute('href');
      }
      if (node.hasAttribute('src')) {
        const url = safeURL(node.getAttribute('src'), base, true);
        if (node.tagName === 'IMG' && url) node.setAttribute('src',url);
        else node.removeAttribute('src');
      }
      if (node.tagName === 'INPUT') { node.disabled = true; if (node.type !== 'checkbox') node.remove(); }
    });
    return fragment;
  }
  function originalBody(html, base) {
    if (!html) return null;
    const doc = new DOMParser().parseFromString(html,'text/html');
    const article = doc.querySelector('article.article');
    // These are the university association site's actual article containers.
    const prose = article?.querySelector('.prose');
    if (!prose || !prose.textContent.trim()) return null;
    const wrapper = document.createElement('div');
    wrapper.append(clean(prose.innerHTML,base));
    const copyright = article.querySelector('.article-copyright');
    if (copyright) wrapper.append(clean(copyright.outerHTML,base));
    return wrapper;
  }
  function markdownBody(value, data) {
    // The BFF includes the page's header. Remove only an exact leading metadata
    // line and matching title; preserve all other article headings and wording.
    let source = value.replace(/\r\n?/g,'\n');
    const metadata = `${data.category} ${data.published}`.trim();
    const hasPageHeader=Boolean(metadata) && source.startsWith(metadata+'\n\n');
    if (hasPageHeader) source = source.slice(metadata.length+2);
    const title = '# '+data.title;
    if (source.startsWith(title+'\n\n')) source = source.slice(title.length+2);
    if (hasPageHeader && data.summary && source.startsWith(data.summary)) {
      source=source.slice(data.summary.length);
      const tags=new Set([data.category,...(data.tags || [])]);
      while (true) {
        const tag=/^\[\s*([^\]\n]+?)\s*\]\(([^)\n]+)\)/.exec(source);
        if (!tag || !tags.has(tag[1].trim())) break;
        let url; try { url=new URL(tag[2],data.url); } catch (_) { break; }
        if (url.origin!==new URL(data.url).origin || !url.pathname.startsWith('/tags/')) break;
        source=source.slice(tag[0].length);
      }
      source=source.trimStart();
    }
    const wrapper = document.createElement('div');
    wrapper.append(clean(md.render(source || data.summary || ''),data.url));
    return wrapper;
  }
  function slug(text) {
    return text.toLowerCase().trim().replace(/[^\p{L}\p{N}\s_-]/gu,'').replace(/\s+/g,'-');
  }
  function render(data) {
    const root = document.getElementById('reader'); root.replaceChildren();
    const cover = safeURL(data.cover,data.url,true);
    if (cover) { const img = document.createElement('img'); img.className='article-cover'; img.src=cover; img.alt=''; root.append(img); }
    const header = document.createElement('header'); header.className='article-header';
    const text = (tag, value, className) => { const node=document.createElement(tag); node.textContent=value; node.className=className; return node; };
    header.append(text('div',data.category,'category'),text('h1',data.title,'article-title'),
      ...(data.summary?[text('p',data.summary,'article-summary')]:[]),
      text('div',[data.author,data.published].filter(Boolean).join(' · '),'metadata'));
    if (data.tags?.length) header.append(text('div',data.tags.map(t=>'#'+t).join('  '),'tags'));
    root.append(header);
    const content = originalBody(data.originalHTML,data.url) || markdownBody(data.markdown,data);
    content.id='article-body'; root.append(content);
    const ids = new Set(Array.from(content.querySelectorAll('[id]'),n=>n.id));
    content.querySelectorAll('h1,h2,h3,h4,h5,h6').forEach(heading => {
      if (heading.id) return;
      let id=slug(heading.textContent), key=id, i=1;
      while (ids.has(key)) key=id+'-'+i++;
      heading.id=key; ids.add(key);
    });
    content.querySelectorAll('table').forEach(table => {
      const scroll=document.createElement('div'); scroll.className='table-scroll'; scroll.tabIndex=0;
      table.replaceWith(scroll); scroll.append(table);
    });
    content.querySelectorAll('img').forEach(img => { img.loading='lazy'; img.decoding='async'; img.removeAttribute('width'); img.removeAttribute('height'); });
    root.querySelectorAll('img').forEach(img => img.addEventListener('error',()=>img.classList.add('broken-image')));
    const original = safeURL(data.url,data.url);
    if (original) { const link=text('a','在官网阅读原文','original-link'); link.href=original; root.append(link); }
    root.onclick = event => {
      const link=event.target.closest('a[href]'); if (!link) return;
      const href=link.getAttribute('href'), target=safeURL(href,data.url); if (!target) return;
      event.preventDefault();
      const url=new URL(target), article=new URL(data.url || 'https://nbtca.space/');
      if (url.origin===article.origin && url.pathname.replace(/\/$/,'')===article.pathname.replace(/\/$/,'') && url.hash) {
        let id; try { id=decodeURIComponent(url.hash.slice(1)); } catch (_) { return; }
        const heading=document.getElementById(id); if (heading) { heading.scrollIntoView(); return; }
      }
      window.webkit?.messageHandlers?.articleLink?.postMessage(target);
    };
  }
  function appearance(size,dark) {
    if (Number.isFinite(size) && size>=12 && size<=80) document.documentElement.style.fontSize=size+'px';
    document.documentElement.dataset.theme=dark?'dark':'light';
  }
  window.ArticleReader={render,appearance,originalBody,markdownBody};
})();
