" scan JS/TS/HTML buffers for bare import specifiers
scriptencoding utf-8

let s:save_cpo = &cpo
set cpo&vim

function! importmap#scan#ExtractFromHtml(lines) abort
  let l:s = join(a:lines, "\n")
  let l:open_pat = '\c<script\%(\_s\%(\_[^>"'']\|"\_[^"]*"\|''\_[^'']*''\)*\)\?>'
  let l:bodies = []
  let l:pos = 0
  while 1
    let l:m = matchstrpos(l:s, l:open_pat, l:pos)
    if l:m[1] == -1
      break
    endif
    let l:pos = l:m[2]
    if l:m[0] !~? 'type\s*=\s*["'']\?module["'']\?'
      continue
    endif
    let l:close = match(l:s, '\c</script\s*>', l:m[2])
    if l:close == -1
      call add(l:bodies, strpart(l:s, l:m[2]))
      break
    endif
    call add(l:bodies, strpart(l:s, l:m[2], l:close - l:m[2]))
    let l:pos = matchend(l:s, '\c</script\s*>', l:m[2])
  endwhile
  return importmap#scan#ExtractSpecifiers(l:bodies)
endfunction

function! importmap#scan#ReduceSubpath(spec) abort
  if a:spec =~# '^@[^/]\+/'
    let l:parts = split(a:spec, '/')
    if len(l:parts) >= 2
      return l:parts[0] . '/' . l:parts[1]
    endif
  else
    let l:parts = split(a:spec, '/')
    if !empty(l:parts)
      return l:parts[0]
    endif
  endif
  return a:spec
endfunction

function! importmap#scan#ExtractSpecifiers(lines) abort
  let l:text = type(a:lines) ==# type([]) ? join(a:lines, "\n") : a:lines
  " drop block comments and whole-line comments so commented-out imports
  " never reach the install prompt
  let l:text = substitute(l:text, '/\*\_.\{-}\*/', ' ', 'g')
  let l:text = substitute(l:text, '\%(^\|\n\)\zs\s*//[^\n]*', '', 'g')

  let l:specs = []
  " the from clause excludes ; and quotes so one match cannot span
  " statements; \_ variants let a single import wrap across lines
  let l:patterns = [
        \ '\<\%(import\|export\)\>\_[^;"'']\{-}\<from\>\_s*["'']\([^"'' >]\+\)["'']',
        \ '\<import\_s*["'']\([^"'' >]\+\)["'']',
        \ '\<import\_s*(\_s*["'']\([^"'' >]\+\)["'']\_s*)',
        \ '\<import\_s*(\_s*`\([^`$]\+\)`\_s*)',
        \ '\<import\.meta\.resolve\_s*(\_s*["'']\([^"'' >]\+\)["'']\_s*)'
        \ ]
  for l:pat in l:patterns
    let l:offset = 0
    while 1
      let l:idx = match(l:text, l:pat, l:offset)
      if l:idx == -1
        break
      endif
      let l:m = matchlist(l:text, l:pat, l:offset)
      if empty(l:m) || empty(l:m[1])
        break
      endif
      if l:m[1] !~# '^\(\.\/\|\.\.\/\|\/\|http:\|https:\|data:\|node:\)'
        call add(l:specs, l:m[1])
      endif
      let l:offset = l:idx + strlen(l:m[0])
    endwhile
  endfor

  return uniq(sort(l:specs))
endfunction

function! importmap#scan#Buffer() abort
  let l:lines = getline(1, '$')
  let l:is_html = (expand('%:e') =~? '^\(html\|htm\)$' || &filetype ==# 'html')
  let l:raw_specs = l:is_html ? importmap#scan#ExtractFromHtml(l:lines) : importmap#scan#ExtractSpecifiers(l:lines)
  let l:reduced = map(copy(l:raw_specs), 'importmap#scan#ReduceSubpath(v:val)')
  return uniq(sort(l:reduced))
endfunction

function! importmap#scan#Sync(bang) abort
  let l:buffer_pkgs = importmap#scan#Buffer()
  if empty(l:buffer_pkgs)
    call importmap#util#Info('no bare imports found in current buffer')
    return
  endif

  let l:target = importmap#html#LocateTarget()
  let l:map_meta = importmap#html#ReadMap(l:target)
  let l:imports = get(l:map_meta.parsed, 'imports', {})
  let l:missing = []

  for l:pkg in l:buffer_pkgs
    if !has_key(l:imports, l:pkg) && !has_key(l:imports, l:pkg . '/')
      call add(l:missing, l:pkg)
    endif
  endfor

  if empty(l:missing)
    call importmap#util#Info('all bare imports in buffer are already in import map')
    return
  endif

  if !a:bang
    let l:prompt = "The following packages will be installed at @latest:\n" . join(map(copy(l:missing), 'v:val . "@latest"'), "\n") . "\nProceed?"
    if confirm(l:prompt, "&Yes\n&No", 1) != 1
      return
    endif
  endif

  let l:install_args = map(copy(l:missing), 'v:val . "@latest"')
  call importmap#Install(l:install_args, a:bang)
endfunction

let &cpo = s:save_cpo
unlet s:save_cpo
