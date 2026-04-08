import lldb

def odin_string_summary(value, internal_dict):
    """Display Odin string as "text" instead of {data=..., len=...}"""
    try:
        data_ptr = value.GetChildMemberWithName('data')
        length   = value.GetChildMemberWithName('len').GetValueAsSigned()
        if length <= 0 or not data_ptr.IsValid():
            return '""'
        length  = min(length, 512)
        process = value.GetProcess()
        error   = lldb.SBError()
        addr    = data_ptr.GetValueAsUnsigned()
        raw     = process.ReadMemory(addr, length, error)
        if error.Success():
            return '"' + raw.decode('utf-8', errors='replace') + '"'
    except Exception:
        pass
    return '""'


def odin_slice_summary(value, internal_dict):
    """Display Odin slice as [len]T instead of {data=..., len=..., cap=...}"""
    try:
        length = value.GetChildMemberWithName('len').GetValueAsSigned()
        cap    = value.GetChildMemberWithName('cap').GetValueAsSigned()
        return f'len={length}, cap={cap}'
    except Exception:
        pass
    return '{...}'


def __lldb_init_module(debugger, internal_dict):
    debugger.HandleCommand(
        'type summary add --python-function odin_lldb.odin_string_summary "string"'
    )
    debugger.HandleCommand(
        'type summary add --python-function odin_lldb.odin_slice_summary '
        '--regex "^\\[dynamic\\]"'
    )
    print('[odin_lldb] Odin type formatters loaded.')
