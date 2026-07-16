" importmap.vim   Manage JavaScript import maps without leaving Vim
" Author:         patrickkettner
" HomePage:       http://github.com/patrickkettner/importmap.vim
" Readme:         http://github.com/patrickkettner/importmap.vim/blob/main/README.md
" Version:        1.0.0

if exists('g:loaded_importmap') || &compatible
  finish
endif
let g:loaded_importmap = 1

let s:save_cpo = &cpo
set cpo&vim

let g:importmap_cdn = get(g:, 'importmap_cdn', 'esm.sh')
let g:importmap_prefix_mappings = get(g:, 'importmap_prefix_mappings', 1)
let g:importmap_registry_url = get(g:, 'importmap_registry_url', 'https://registry.npmjs.org')
let g:importmap_html_candidates = get(g:, 'importmap_html_candidates', ['index.html', 'public/index.html', 'src/index.html', 'www/index.html'])
let g:importmap_target = get(g:, 'importmap_target', '')
let g:importmap_root_markers = get(g:, 'importmap_root_markers', ['.git', '.hg', 'package.json', 'index.html'])
let g:importmap_curl = get(g:, 'importmap_curl', 'curl')
let g:importmap_timeout = get(g:, 'importmap_timeout', 10)
let g:importmap_cache_ttl = get(g:, 'importmap_cache_ttl', 300)
let g:importmap_indent = get(g:, 'importmap_indent', 2)
let g:importmap_esm_sh_flags = get(g:, 'importmap_esm_sh_flags', '')
let g:importmap_openssl = get(g:, 'importmap_openssl', 'openssl')
let g:importmap_sync = get(g:, 'importmap_sync', 0)
let g:importmap_log = get(g:, 'importmap_log', '')
let g:importmap_cache_dir = get(g:, 'importmap_cache_dir', '')

command! -nargs=* -bang -bar -complete=customlist,importmap#Complete ImportMap call importmap#Dispatch([<f-args>], <bang>0)
command! -nargs=* -bang -bar -complete=customlist,importmap#Complete Bower call importmap#Bower([<f-args>], <bang>0)

let &cpo = s:save_cpo
unlet s:save_cpo
