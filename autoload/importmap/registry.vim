" npm registry client with caching and search
scriptencoding utf-8

let s:save_cpo = &cpo
set cpo&vim

function! s:UrlEncode(str) abort
  return substitute(a:str, '[^a-zA-Z0-9_.-]', '\=printf("%%%02X", char2nr(submatch(0)))', 'g')
endfunction

function! importmap#registry#Url(parts, query) abort
  if type(a:parts) ==# type([])
    let l:encoded_parts = []
    for l:part in a:parts
      if l:part =~# '^@[^/]\+/'
        call add(l:encoded_parts, substitute(l:part, '/', '%2F', 'g'))
      else
        call add(l:encoded_parts, l:part)
      endif
    endfor
    let l:path = join(l:encoded_parts, '/')
  else
    let l:path = a:parts
    if l:path =~# '^@[^/]\+/'
      let l:path = substitute(l:path, '/', '%2F', 'g')
    endif
  endif

  let l:base = substitute(g:importmap_registry_url, '/$', '', '')
  if l:path =~# '^/'
    let l:path = l:path[1:]
  endif
  let l:url = l:base . '/' . l:path

  if type(a:query) ==# type({}) && !empty(a:query)
    let l:qparts = []
    for [l:k, l:v] in items(a:query)
      call add(l:qparts, s:UrlEncode(l:k) . '=' . s:UrlEncode(l:v))
    endfor

    let l:url .= '?' . join(l:qparts, '&')
  elseif type(a:query) ==# type('') && !empty(a:query)
    let l:url .= '?' . a:query
  endif

  return l:url
endfunction

function! importmap#registry#GetMetadata(name, bang, on_done) abort
  let l:url = importmap#registry#Url([a:name], '')
  let l:hash = sha256(l:url)

  let l:cache_file = importmap#util#CacheDir() . '/' . l:hash . '.json'

  if !a:bang && filereadable(l:cache_file)
    if localtime() - getftime(l:cache_file) < g:importmap_cache_ttl
      try
        let l:doc = json_decode(join(readfile(l:cache_file), "\n"))
        call importmap#util#Log('Registry cache hit: ' . a:name)
        call call(a:on_done, [l:doc])
        return
      catch
        " Cache read/decode failed, proceed to network
      endtry
    endif
  endif

  call importmap#util#Log('Registry fetch: ' . a:name)
  call importmap#job#GetJson(l:url, ['Accept: application/vnd.npm.install-v1+json'], {
        \ 'on_done': function('s:OnGetMetadataDone', [l:cache_file, a:on_done])
        \ })
endfunction

function! s:OnGetMetadataDone(cache_file, on_done, doc) abort
  if type(a:doc) ==# type({})
    try
      call writefile([json_encode(a:doc)], a:cache_file)
    catch
      " Ignore write failure
    endtry
  endif
  call call(a:on_done, [a:doc])
endfunction


function! importmap#registry#GetMetadataSync(name, timeout_ms) abort
  let l:url = importmap#registry#Url([a:name], '')
  let l:hash = sha256(l:url)
  let l:cache_file = importmap#util#CacheDir() . '/' . l:hash . '.json'

  if filereadable(l:cache_file)
    if localtime() - getftime(l:cache_file) < g:importmap_cache_ttl
      try
        return json_decode(join(readfile(l:cache_file), "\n"))
      catch
      endtry
    endif
  endif

  let l:cmd = [g:importmap_curl, '-sfL', '--max-time', string(max([1, a:timeout_ms / 1000])), '-H', 'Accept: application/vnd.npm.install-v1+json', l:url]
  let l:res = importmap#job#RunSync(l:cmd, a:timeout_ms)
  if l:res.code == 0
    try
      let l:doc = json_decode(join(l:res.lines, "\n"))
      call writefile([json_encode(l:doc)], l:cache_file)
      return l:doc
    catch
    endtry
  endif
  return v:null
endfunction

function! importmap#registry#Search(text, on_done) abort
  let l:url = importmap#registry#Url(['-', 'v1', 'search'], 'text=' . s:UrlEncode(a:text) . '&size=20')
  call importmap#job#GetJson(l:url, [], {'on_done': a:on_done})
endfunction

function! importmap#registry#SearchSync(text, timeout_ms) abort
  let l:url = importmap#registry#Url(['-', 'v1', 'search'], 'text=' . s:UrlEncode(a:text) . '&size=20')
  let l:cmd = [g:importmap_curl, '-sfL', '--max-time', string(max([1, a:timeout_ms / 1000])), l:url]
  let l:res = importmap#job#RunSync(l:cmd, a:timeout_ms)
  if l:res.code == 0
    try
      return json_decode(join(l:res.lines, "\n"))
    catch
    endtry
  endif
  return v:null
endfunction

let &cpo = s:save_cpo
unlet s:save_cpo
