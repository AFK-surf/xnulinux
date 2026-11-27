#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
# Reads xnu_m2v.h and writes the regular functions' two ends: gen_client.inc (the call as a message) and gen_server.inc
# (the message as a call). What it cannot do by rule is listed in MANUAL and written by hand in client.c / server.c.
import os, re, sys
HERE = os.path.dirname(os.path.abspath(__file__))
# usage: gen.py [xnu_m2v.h]; writes beside itself
src = open(sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, '../xnu-cpu-metal/src/xnu-m2v-bridge/include/xnu_m2v.h')).read()
os.chdir(HERE)
src = re.sub(r'/\*.*?\*/', '', src, flags=re.S)
src = re.sub(r'//[^\n]*', '', src)
HANDLES = re.findall(r'typedef struct (Xm2v\w+) \1;', src)
BLOBS = ['Xm2vTextureDesc', 'Xm2vSamplerDesc', 'Xm2vDepthStencilDesc']
SCALARS = {'uint64_t', 'uint32_t', 'int64_t', 'bool', 'uint8_t', 'size_t', 'float', 'double'}
MANUAL = set('''xm2v_last_error xm2v_device_open xm2v_device_open_direct xm2v_device_release xm2v_device_name
xm2v_device_max_threads_per_threadgroup xm2v_buffer_new xm2v_buffer_new_page_aligned xm2v_buffer_new_no_copy
xm2v_buffer_new_no_copy_dealloc xm2v_buffer_release xm2v_buffer_contents xm2v_buffer_length xm2v_buffer_did_modify_range
xm2v_texture_replace_region xm2v_texture_get_bytes xm2v_library_new_with_data xm2v_library_function_name_at
xm2v_library_extern_function_name_at xm2v_library_new_function_specialized xm2v_library_new_function_specialized_zero_rest
xm2v_library_new_function_with_descriptor xm2v_argument_encoder_constant_data xm2v_compute_pipeline_new_with_linked
xm2v_render_pipeline_new xm2v_command_buffer_commit xm2v_command_buffer_wait_until_completed xm2v_command_buffer_error
xm2v_render_encoder_new xm2v_compute_encoder_set_bytes xm2v_render_encoder_set_vertex_bytes xm2v_render_encoder_set_fragment_bytes
xm2v_shared_event_notify xm2v_shared_event_wait_until xm2v_pixel_format_is_ycbcr xm2v_command_buffer_status xm2v_command_buffer_new xm2v_command_buffer_release xm2v_texture_gpu_resource_id xm2v_sampler_gpu_resource_id xm2v_buffer_gpu_address
xm2v_argument_encoder_set_argument_buffer xm2v_argument_encoder_set_argument_buffer_array_element xm2v_argument_encoder_set_buffer
xm2v_argument_encoder_set_texture xm2v_argument_encoder_set_sampler xm2v_argument_encoder_set_compute_pipeline
xm2v_argument_encoder_set_render_pipeline'''.split())
# creations answered (ok or not): rare, and their callers act on a failure
SYNC_NEW = set('''xm2v_library_new_function xm2v_library_new_extern_function xm2v_compute_pipeline_new xm2v_function_new_argument_encoder
xm2v_argument_encoder_new_nested xm2v_shared_event_new_with_handle xm2v_shared_event_new_handle'''.split())
SYNC_BOOL = set('''xm2v_device_supports_family'''.split())
# buffers the GPU may write: (function, parameter)
WRITES = {('xm2v_blit_encoder_copy_buffer_to_buffer', 'dst'), ('xm2v_blit_encoder_copy_texture_to_buffer', 'dst'),
          ('xm2v_blit_encoder_fill_buffer', 'buf'), ('xm2v_blit_encoder_synchronize_buffer', 'buf'),
          ('xm2v_compute_encoder_set_buffer', 'buf'), ('xm2v_compute_encoder_use_buffer', 'buf'), ('xm2v_render_encoder_use_buffer', 'buf')}
ENDS = lambda n: n.endswith('_encoder_end')
protos = re.findall(r'^\s*((?:const\s+)?[A-Za-z_][\w ]*?[\s\*]+)(xm2v_\w+)\s*\(([^;{]*?)\)\s*;', src, flags=re.M | re.S)
ops, cl, sv, manual, names = [], [], [], [], []
def parse_param(p):
    p = ' '.join(p.split())
    m = re.match(r'(.*?)(\w+)(\[\d+\])?$', p)
    t, n = m.group(1).strip(), m.group(2)
    return t, n, m.group(3)
for ret, name, params in protos:
    ret = ' '.join(ret.split()); names.append(name)
    ps = [] if params.strip() in ('', 'void') else [parse_param(p) for p in params.split(',')]
    ops.append(name)
    if name in MANUAL: manual.append(name); continue
    kinds = []; ok = True
    for t, n, arr in ps:
        base = t.replace('const', '').replace('*', '').strip()
        if arr: ok = False
        elif base in HANDLES and '*' in t: kinds.append(('h', base, n))
        elif base in BLOBS and '*' in t: kinds.append(('b', base, n))
        elif base in SCALARS and '*' not in t: kinds.append(('s', base, n))
        elif t.replace(' ', '') == 'constchar*': kinds.append(('z', base, n))
        else: ok = False
    rbase = ret.replace('const', '').replace('*', '').strip()
    if not ok or not (ret in ('void', 'bool', 'uint64_t', 'uint32_t', 'size_t') or (rbase in HANDLES and '*' in ret)):
        print('cannot generate', name, ret, ps, file=sys.stderr); manual.append(name); continue
    isnew = rbase in HANDLES
    sync = (ret in ('uint64_t', 'uint32_t', 'size_t')) or name in SYNC_NEW or name in SYNC_BOOL
    release = name.endswith('_release'); end = ENDS(name)
    sig = ', '.join(f'{t} {n}' for t, n, _ in ps) or 'void'
    c = [f'{ret} {name}({sig}) {{']
    first = kinds[0] if kinds and kinds[0][0] == 'h' else None
    c.append('    xr_lock();')
    if isnew: c.append(f'    struct xh *nh = xr_new(K_{rbase}, {"(struct xh *)" + first[2] if first else "0"});')
    c.append(f'    uint8_t *m = xr_begin(OP_{name}, {"xr_req()" if sync else "0"});')
    if sync: c.append('    uint64_t req = xr_cur_req;')
    if isnew: c.append('    m = xr_u64(m, nh->id);')
    for k, base, n in kinds:
        if k == 'h':
            c.append(f'    m = xr_u64(m, XID({n}));')
            if base == 'Xm2vBuffer' and first and first[1] in ('Xm2vComputeEncoder', 'Xm2vRenderEncoder', 'Xm2vBlitEncoder', 'Xm2vCommandBuffer'):
                w = '1' if (name, n) in WRITES else '0'
                if name == 'xm2v_render_encoder_use_buffer': w = '(usage & 2) != 0'
                c.append(f'    xr_ref_buffer((struct xh *){first[2]}, (struct xh *){n}, {w});')
            if base == 'Xm2vTexture' and first and first[1] in ('Xm2vComputeEncoder', 'Xm2vRenderEncoder', 'Xm2vBlitEncoder', 'Xm2vCommandBuffer'):
                c.append(f'    xr_ref_texture((struct xh *){first[2]}, (struct xh *){n});')
        elif k == 'b': c.append(f'    m = xr_bytes(m, {n}, sizeof *{n});')
        elif k == 'z': c.append(f'    m = xr_str(m, {n});')
        elif base in ('float', 'double'): c.append(f'    m = xr_f64(m, {n});')
        else: c.append(f'    m = xr_u64(m, (uint64_t){n});')
    c.append('    xr_end(m);')
    if isnew and name.endswith('_new_texture') or name.endswith('_new_linear_texture') or name.endswith('_ycbcr') or name == 'xm2v_texture_new_view':
        if first and first[1] == 'Xm2vBuffer': c.append(f'    nh->buf = (struct xh *){first[2]}; xr_retain(nh->buf);')
        if first and first[1] == 'Xm2vTexture': c.append(f'    nh->buf = ((struct xh *){first[2]})->buf; if (nh->buf) xr_retain(nh->buf);')
    if release or end: c.append(f'    xr_free((struct xh *){first[2]});')
    if sync:
        c.append('    uint64_t r = xr_wait_u64(req);')   # drops the lock
        if isnew: c.append(f'    if (!r) {{ xr_lock(); xr_free(nh); xr_unlock(); return 0; }}\n    return ({ret})nh;')
        elif ret == 'bool': c.append('    return r != 0;')
        else: c.append(f'    return ({ret})r;')
    else:
        c.append('    xr_unlock();')
        if isnew: c.append(f'    return ({ret})nh;')
        elif ret == 'bool': c.append('    return true;')
    c.append('}')
    cl.append('\n'.join(c))
    s = [f'case OP_{name}: {{']
    args = []
    if isnew: s.append('    uint64_t nid = sv_u64(&m);')
    for i, (k, base, n) in enumerate(kinds):
        if k == 'h': s.append(f'    uint64_t i{i} = sv_u64(&m); {base} *a{i} = sv_obj(i{i}); if (!a{i}) {{ sv_null(h.op, {i}); {"sv_set(nid, 0); " if isnew else ""}{"sv_answer_u64(h.req, 0); " if sync else ""}break; }}'); args.append(f'a{i}')
        elif k == 'b': s.append(f'    {base} *a{i} = (void *)m; m += (sizeof({base}) + 7) & ~7ul;'); args.append(f'a{i}')
        elif k == 'z': s.append(f'    const char *a{i} = sv_str(&m);'); args.append(f'a{i}')
        elif base in ('float', 'double'): s.append(f'    double a{i} = sv_f64(&m);'); args.append(f'({base})a{i}')
        else: s.append(f'    uint64_t a{i} = sv_u64(&m);'); args.append(f'({base})a{i}')
    call = f'{name}({", ".join(args)})'
    if isnew:
        s.append(f'    void *o = {call}; sv_set(nid, o); if (!o) sv_fail(h.op);')
        if sync: s.append('    sv_answer_u64(h.req, o != 0);')
    elif sync: s.append(f'    sv_answer_u64(h.req, (uint64_t){call});')
    elif ret == 'bool': s.append(f'    if (!{call}) sv_fail(h.op);')
    else: s.append(f'    {call};')
    if release or end: s.append('    sv_set(i0, 0);')
    s.append('    break; }')
    sv.append('\n'.join(s))
open('gen_ops.h', 'w').write('enum {\n    OP_NONE,\n' + ''.join(f'    OP_{n},\n' for n in ops) + '    OP_BUFFER_WRITE, OP_BUFFER_READ, OP_COUNT\n};\n' +
    'static const char *const op_names[] = { "none", ' + ', '.join(f'"{n[5:]}"' for n in ops) + ', "buffer_write", "buffer_read" };\n' +
    'enum { K_NONE, ' + ', '.join('K_' + h for h in HANDLES) + ' };\n')
open('gen_client.inc', 'w').write('\n'.join(cl) + '\n')
open('gen_server.inc', 'w').write('\n'.join(sv) + '\n')
# The library that is either: every function goes to the real libxnu_m2v beside it or to the remote one (switch.c).
ren, sw = [], []
for ret, name, params in protos:
    ret = ' '.join(ret.split()); params = ' '.join(params.split())
    ps = [] if params in ('', 'void') else [parse_param(p) for p in params.split(',')]
    args = ', '.join(n for _, n, _ in ps)
    ptr = f'{ret} (*{name})({params or "void"})'
    ren.append(f'#define {name} xr_{name}')
    sw.append((ptr, f'{ret} xr_{name}({params or "void"});\n{ret} {name}({params or "void"}) {{ {"" if ret == "void" else "return "}(xs_remote() ? xr_{name} : xs_local.{name})({args}); }}', name))
open('gen_rename.h', 'w').write('\n'.join(ren) + '\n')
open('gen_switch.inc', 'w').write('static struct {\n' + ''.join(f'    {p};\n' for p, _, _ in sw) + '} xs_local;\nstatic int xs_remote(void);\n' +
    '\n'.join(b for _, b, _ in sw) + '\nstatic const char *const xs_names[] = { ' + ', '.join(f'"{n}"' for _, _, n in sw) + ' };\n')
print(len(ops), 'functions,', len(cl), 'generated,', len(manual), 'by hand:', ' '.join(m[5:] for m in manual))
