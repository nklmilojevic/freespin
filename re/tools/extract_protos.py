# /// script
# dependencies = ["protobuf>=5"]
# ///
"""Carve serialized FileDescriptorProto blobs out of a binary and render .proto files."""
import os
import re
import sys

from google.protobuf import descriptor_pb2 as d

LABEL = {1: "optional", 2: "required", 3: "repeated"}
TYPE = {1: "double", 2: "float", 3: "int64", 4: "uint64", 5: "int32", 6: "fixed64", 7: "fixed32",
        8: "bool", 9: "string", 12: "bytes", 13: "uint32", 15: "sfixed32", 16: "sfixed64",
        17: "sint32", 18: "sint64"}


def read_varint(buf, i):
    shift = val = 0
    while True:
        b = buf[i]
        val |= (b & 0x7F) << shift
        i += 1
        if not b & 0x80:
            return val, i
        shift += 7
        if shift > 35:
            raise ValueError


def carve(data):
    found = {}
    for m in re.finditer(rb"[A-Za-z0-9_/]+\.proto", data):
        name = m.group(0)
        # FileDescriptorProto starts with field 1 (name): 0x0a <len> <name>
        for back in (2, 3):
            start = m.start() - back
            if start < 0 or data[start] != 0x0A:
                continue
            try:
                ln, p = read_varint(data, start + 1)
            except (ValueError, IndexError):
                continue
            if p != m.start() or ln != len(name):
                continue
            end = wire_end(data, start)
            fd = d.FileDescriptorProto()
            try:
                fd.ParseFromString(data[start:end])
            except Exception:
                continue
            if fd.name == name.decode() and (fd.message_type or fd.enum_type or fd.service):
                found.setdefault(fd.name, data[start:end])
    return found


# FileDescriptorProto top-level fields and their wire types (2 = length-delimited, 0 = varint)
FDP_FIELDS = {1: 2, 2: 2, 3: 2, 4: 2, 5: 2, 6: 2, 7: 2, 8: 2, 9: 2, 10: 0, 11: 0, 12: 2, 14: 0}


def wire_end(data, i):
    """Walk top-level tags while they are valid FileDescriptorProto fields."""
    while i < len(data):
        try:
            tag, p = read_varint(data, i)
        except (ValueError, IndexError):
            return i
        field, wt = tag >> 3, tag & 7
        if FDP_FIELDS.get(field) != wt:
            return i
        try:
            val, p = read_varint(data, p)
        except (ValueError, IndexError):
            return i
        if wt == 2:
            if p + val > len(data):
                return i
            p += val
        i = p
    return i


def tname(f, pkg):
    if f.type in (11, 14):
        n = f.type_name
        return n[len(pkg) + 2:] if pkg and n.startswith("." + pkg + ".") else n.lstrip(".")
    return TYPE[f.type]


def render_enum(e, ind):
    out = [f"{ind}enum {e.name} {{"]
    out += [f"{ind}  {v.name} = {v.number};" for v in e.value]
    out.append(f"{ind}}}")
    return out


def render_msg(m, pkg, ind, syntax):
    out = [f"{ind}message {m.name} {{"]
    maps = {n.name: n for n in m.nested_type if n.options.map_entry}
    for e in m.enum_type:
        out += render_enum(e, ind + "  ")
    for n in m.nested_type:
        if not n.options.map_entry:
            out += render_msg(n, pkg, ind + "  ", syntax)
    oneofs = {}
    for f in m.field:
        if f.HasField("oneof_index") and not f.proto3_optional:
            oneofs.setdefault(f.oneof_index, []).append(f)
    emitted = set()
    for f in m.field:
        if f.HasField("oneof_index") and not f.proto3_optional:
            if f.oneof_index in emitted:
                continue
            emitted.add(f.oneof_index)
            out.append(f"{ind}  oneof {m.oneof_decl[f.oneof_index].name} {{")
            for g in oneofs[f.oneof_index]:
                out.append(f"{ind}    {tname(g, pkg)} {g.name} = {g.number};")
            out.append(f"{ind}  }}")
            continue
        short = f.type_name.rsplit(".", 1)[-1]
        if f.label == 3 and short in maps:
            me = maps[short]
            out.append(f"{ind}  map<{tname(me.field[0], pkg)}, {tname(me.field[1], pkg)}> {f.name} = {f.number};")
            continue
        lab = LABEL[f.label]
        if syntax == "proto3" and lab == "optional" and not f.proto3_optional:
            lab = ""
        dflt = f" [default = {f.default_value}]" if f.default_value else ""
        out.append(f"{ind}  {(lab + ' ') if lab else ''}{tname(f, pkg)} {f.name} = {f.number}{dflt};")
    out.append(f"{ind}}}")
    return out


def render(fd):
    syntax = fd.syntax or "proto2"
    out = [f'syntax = "{syntax}";', ""]
    if fd.package:
        out += [f"package {fd.package};", ""]
    out += [f'import "{i}";' for i in fd.dependency]
    out.append("")
    for e in fd.enum_type:
        out += render_enum(e, "") + [""]
    for m in fd.message_type:
        out += render_msg(m, fd.package, "", syntax) + [""]
    for s in fd.service:
        out.append(f"service {s.name} {{")
        for r in s.method:
            out.append(f"  rpc {r.name}({r.input_type.lstrip('.')}) returns ({r.output_type.lstrip('.')});")
        out += ["}", ""]
    return "\n".join(out)


def main():
    binary, outdir = sys.argv[1], sys.argv[2]
    data = open(binary, "rb").read()
    found = carve(data)
    for name, blob in sorted(found.items()):
        fd = d.FileDescriptorProto.FromString(blob)
        path = os.path.join(outdir, name)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as fh:
            fh.write(render(fd))
    print(f"{len(found)} descriptors written to {outdir}")


if __name__ == "__main__":
    main()
