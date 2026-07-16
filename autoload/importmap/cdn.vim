" CDN URL construction and inverse parsing for esm.sh, jsdelivr, unpkg
scriptencoding utf-8

let s:save_cpo = &cpo
set cpo&vim

function! importmap#cdn#Urls(provider, name, version) abort
  let l:ver = a:version
  if a:provider ==# 'jsdelivr'
    let l:bare = 'https://cdn.jsdelivr.net/npm/' . a:name . '@' . l:ver . '/+esm'
    let l:prefix = 'https://cdn.jsdelivr.net/npm/' . a:name . '@' . l:ver . '/'
  elseif a:provider ==# 'unpkg'
    let l:bare = 'https://unpkg.com/' . a:name . '@' . l:ver . '?module'
    let l:prefix = 'https://unpkg.com/' . a:name . '@' . l:ver . '/'
  else
    " Default to esm.sh
    let l:bare = 'https://esm.sh/' . a:name . '@' . l:ver . g:importmap_esm_sh_flags
    let l:prefix = 'https://esm.sh/' . a:name . '@' . l:ver . '/'
  endif
  return {'bare': l:bare, 'prefix': l:prefix}
endfunction

function! importmap#cdn#ParseUrl(url) abort
  if a:url =~# '^https://esm\.sh/'
    let l:path = substitute(a:url, '^https://esm\.sh/', '', '')
    let l:is_prefix = l:path =~# '/$' || l:path =~# '^[^@]\+@[^/?#]\+/.\+$' || l:path =~# '^@[^/]\+/[^@]\+@[^/?#]\+/.\+$'
    " Check if scoped package @scope/pkg@version or unscoped pkg@version
    if l:path =~# '^@[^/]\+/[^@]\+@'
      let l:m = matchlist(l:path, '^\(@[^/]\+/[^@/]\+\)@\([^/?#]\+\)')
    else
      let l:m = matchlist(l:path, '^\([^@/]\+\)@\([^/?#]\+\)')
    endif
    if !empty(l:m)
      let l:pref_int = l:is_prefix ? 1 : 0
      return {'provider': 'esm.sh', 'name': l:m[1], 'version': l:m[2], 'is_prefix': l:pref_int, 'prefix': l:pref_int, 'valid': 1}
    endif

  elseif a:url =~# '^https://cdn\.jsdelivr\.net/npm/'
    let l:path = substitute(a:url, '^https://cdn\.jsdelivr\.net/npm/', '', '')
    let l:is_prefix = l:path =~# '/$' || (l:path !~# '/+esm$' && l:path =~# '/')
    if l:path =~# '^@[^/]\+/[^@]\+@'
      let l:m = matchlist(l:path, '^\(@[^/]\+/[^@/]\+\)@\([^/?#]\+\)')
    else
      let l:m = matchlist(l:path, '^\([^@/]\+\)@\([^/?#]\+\)')
    endif
    if !empty(l:m)
      let l:pref_int = l:is_prefix ? 1 : 0
      return {'provider': 'jsdelivr', 'name': l:m[1], 'version': l:m[2], 'is_prefix': l:pref_int, 'prefix': l:pref_int, 'valid': 1}
    endif

  elseif a:url =~# '^https://unpkg\.com/'
    let l:path = substitute(a:url, '^https://unpkg\.com/', '', '')
    let l:is_prefix = l:path =~# '/$' || (l:path !~# '?module$' && l:path =~# '/')
    if l:path =~# '^@[^/]\+/[^@]\+@'
      let l:m = matchlist(l:path, '^\(@[^/]\+/[^@/]\+\)@\([^/?#]\+\)')
    else
      let l:m = matchlist(l:path, '^\([^@/]\+\)@\([^/?#]\+\)')
    endif
    if !empty(l:m)
      let l:pref_int = l:is_prefix ? 1 : 0
      return {'provider': 'unpkg', 'name': l:m[1], 'version': l:m[2], 'is_prefix': l:pref_int, 'prefix': l:pref_int, 'valid': 1}
    endif
  endif

  return {'valid': 0}
endfunction

let &cpo = s:save_cpo
unlet s:save_cpo

