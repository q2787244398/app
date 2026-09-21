import re

with open("vbox.xcodeproj/project.pbxproj", "r") as f:
    content = f.read()

# name -> (fileRef, buildFile, group)
new_ids = {
    "BackupManager.swift": ("B10132", "A10132", "Services"),
    "BackupRestoreSheet.swift": ("B10131", "A10131", "Views"),
}

# 幂等：跳过已登记的文件
pending = {}
for name, (fr, bf, group) in new_ids.items():
    if f"{fr} /* {name} */" in content and f"{bf} /* {name} in Sources */" in content:
        print(f"skip {name} (already registered)")
    else:
        pending[name] = (fr, bf, group)

# PBXBuildFile
if pending:
    idx = content.find("/* End PBXBuildFile section */")
    extra = ""
    for name, (fr, bf, _) in pending.items():
        extra += f"\t\t{bf} /* {name} in Sources */ = {{isa = PBXBuildFile; fileRef = {fr} /* {name} */; }};\n"
    content = content[:idx] + extra + content[idx:]

# PBXFileReference
if pending:
    idx = content.find("/* End PBXFileReference section */")
    extra = ""
    for name, (fr, bf, _) in pending.items():
        extra += f'\t\t{fr} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {name}; sourceTree = "<group>"; }};\n'
    content = content[:idx] + extra + content[idx:]

# Views / Services group（按成员幂等补齐）
for group_name in ("Views", "Services"):
    m = re.search(r"([A-Za-z0-9]+) /\* " + group_name + r" \*/ = \{", content)
    if not m:
        continue
    gid = m.group(1)
    pat = r"(\t\t" + re.escape(gid) + r' /\* ' + group_name + r' \*/ = \{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = \(\n)(.*?)(\t\t\t\);)'

    def add_member(m2, gname=group_name):
        h, c, f = m2.groups()
        for name, (fr, bf, g) in new_ids.items():
            if g == gname and fr not in c:
                c += f"\t\t\t\t{fr} /* {name} */,\n"
        return h + c + f

    content = re.sub(pat, add_member, content, count=1, flags=re.DOTALL)

# Sources phase（插入到 build phase 字典内部、闭合括号之前；并清理历史游离行）
if pending:
    orphan_re = re.compile(r"^\t+\t\t\t\t(?:[A-Z0-9]+) /\* .* in Sources \*/,\n(?=/\* End PBXSourcesBuildPhase section \*/)", re.M)
    content = orphan_re.sub("", content)

    idx = content.find("/* Begin PBXSourcesBuildPhase section */")
    end = content.find("/* End PBXSourcesBuildPhase section */", idx)
    segment = content[idx:end]
    # 定位该段内 Sources build phase 的闭合括号：最后一个 ");"（带 buildPhase 缩进）
    close = segment.rfind("\t\t\t);")
    if close == -1:
        raise SystemExit("FATAL: 找不到 PBXSourcesBuildPhase 闭合括号")
    abs_close = idx + close
    extra = ""
    for name, (fr, bf, _) in pending.items():
        extra += f"\t\t\t\t{bf} /* {name} in Sources */,\n"
    content = content[:abs_close] + extra + content[abs_close:]

with open("vbox.xcodeproj/project.pbxproj", "w") as f:
    f.write(content)
print("Done:", ", ".join(pending.keys()) if pending else "group check only")
