" SRI hash computation via curl and openssl
scriptencoding utf-8

let s:save_cpo = &cpo
set cpo&vim

function! importmap#integrity#Run(bang) abort
  if !executable(g:importmap_openssl)
    call importmap#util#Error('openssl not found (set g:importmap_openssl)')
    return
  endif

  let l:target = importmap#html#LocateTarget()
  let l:map_meta = importmap#html#ReadMap(l:target)
  let l:map_dict = l:map_meta.parsed
  let l:imports = get(l:map_dict, 'imports', {})
  let l:scopes = get(l:map_dict, 'scopes', {})
  let l:urls = []

  for [l:k, l:url] in items(l:imports)
    if type(l:url) ==# type('') && l:url !~# '/$' && index(l:urls, l:url) == -1
      call add(l:urls, l:url)
    endif
  endfor
  for [l:scope_key, l:scope_dict] in items(l:scopes)
    if type(l:scope_dict) ==# type({})
      for [l:k, l:url] in items(l:scope_dict)
        if type(l:url) ==# type('') && l:url !~# '/$' && index(l:urls, l:url) == -1
          call add(l:urls, l:url)
        endif
      endfor
    endif
  endfor

  if empty(l:urls)
    call importmap#util#Info('no mapped URLs (non-prefix) to compute integrity for')
    return
  endif

  let l:updated = 0
  for l:url in l:urls
    " the map is data, not something we authored: never hand curl anything
    " but https (file://, http://, and friends all stay untouched)
    if l:url !~# '^https://'
      call importmap#util#Warn('skipping non-https url: ' . l:url)
      continue
    endif
    if !a:bang && !empty(get(get(l:map_dict, 'integrity', {}), l:url, ''))
      continue
    endif

    let l:tmp = tempname()
    let l:tmp2 = tempname()
    try
      let l:curl_cmd = [g:importmap_curl, '-sfL', '--max-time', string(g:importmap_timeout), '--output', l:tmp, l:url]
      let l:res = importmap#job#RunSync(l:curl_cmd, g:importmap_timeout * 1000)
      if l:res.code != 0
        call importmap#util#Warn('failed to fetch ' . l:url . ' for integrity')
        continue
      endif

      let l:dgst_cmd = [g:importmap_openssl, 'dgst', '-sha384', '-binary', '-out', l:tmp2, l:tmp]
      let l:res_dgst = importmap#job#RunSync(l:dgst_cmd, 5000)
      if l:res_dgst.code != 0
        call importmap#util#Warn('openssl dgst failed on ' . l:url)
        continue
      endif

      let l:b64_cmd = [g:importmap_openssl, 'base64', '-A', '-in', l:tmp2]
      let l:res_b64 = importmap#job#RunSync(l:b64_cmd, 5000)
      if l:res_b64.code == 0 && !empty(l:res_b64.lines)
        let l:hash = 'sha384-' . trim(join(l:res_b64.lines, ''))
        if !has_key(l:map_dict, 'integrity') || type(l:map_dict.integrity) !=# type({})
          let l:map_dict.integrity = {}
        endif
        let l:map_dict.integrity[l:url] = l:hash
        call importmap#util#Info('integrity + ' . l:url . ' (' . l:hash[:24] . '...)')
        let l:updated += 1
      else
        call importmap#util#Warn('openssl base64 failed on ' . l:url)
      endif
    finally
      if filereadable(l:tmp)
        call delete(l:tmp)
      endif
      if filereadable(l:tmp2)
        call delete(l:tmp2)
      endif
    endtry
  endfor

  if l:updated > 0 || a:bang
    call importmap#html#WriteMap(l:map_meta.path, l:map_dict, l:map_meta)
    call importmap#util#Info('updated integrity for ' . l:updated . ' URL(s)')
  endif
endfunction

let &cpo = s:save_cpo
unlet s:save_cpo
