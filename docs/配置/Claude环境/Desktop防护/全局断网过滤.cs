// 全局断网开关的 WFP 过滤（x64 Windows ABI）。照经验帖的「断网开关」：只有 Clash 内核、走 TUN 的流量、本机回环和局域网能出网，其余一律拦。
// 独立子层，和「应用直连过滤.cs」互不影响；放行都是软放行（不清除动作权），别的子层的拦截（网段阻断、Claude 程序直连阻断、TUN 的 DNS 防漏）照样生效。
// 动态会话（Dynamic）：过滤跟着会话句柄走，进程退出自动消失，用于试装；常驻（Persistent）：重启后仍在，用于正式安装。
using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;

namespace ClaudeNetworkGuard
{
    public sealed class KillSwitchFilterInfo
    {
        public Guid Key { get; internal set; }
        public string Name { get; internal set; }
        public bool Persistent { get; internal set; }
        public uint Action { get; internal set; }
        public ulong Id { get; internal set; }
        public bool AccessDenied { get; internal set; }
    }

    public sealed class KillSwitchSession : IDisposable
    {
        internal IntPtr Handle;
        public bool Dynamic { get; internal set; }
        public void Dispose()
        {
            if (Handle != IntPtr.Zero) { GlobalKillSwitch.CloseEngine(Handle); Handle = IntPtr.Zero; }
        }
    }

    public static class GlobalKillSwitch
    {
        public static readonly Guid SubLayerKey = new Guid("6a1e3c52-9b47-4d2f-8e1a-0c5d7f3b9e21");
        private static readonly Guid LayerV4 = new Guid("c38d57d1-05a7-4c33-904f-7fbceee60e82"); // ALE_AUTH_CONNECT_V4
        private static readonly Guid LayerV6 = new Guid("4a72393b-319f-44bc-84c3-ba54dcb3b6b4"); // ALE_AUTH_CONNECT_V6
        private static readonly Guid AppIdKey = new Guid("d78e1e87-8644-4ea5-9437-d809ecefc971");
        private static readonly Guid FlagsKey = new Guid("632ce23b-5167-435c-86d7-e903684aa80c");
        private static readonly Guid LocalAddressKey = new Guid("d9ee00de-c1ef-4617-bfe3-ffd8f5a08957");
        private static readonly Guid RemoteAddressKey = new Guid("b235ae9a-1d64-49b8-a44c-5ff3d9095045");

        // 固定 GUID：安装、校验、删除都只认这几个，不枚举、不碰别人的过滤。
        public static readonly Guid V4Core = new Guid("6a1e3c52-9b47-4d2f-8e1a-0c5d7f3b9e31");
        public static readonly Guid V4Loopback = new Guid("6a1e3c52-9b47-4d2f-8e1a-0c5d7f3b9e32");
        public static readonly Guid V4Tun = new Guid("6a1e3c52-9b47-4d2f-8e1a-0c5d7f3b9e33");
        public static readonly Guid V4Lan = new Guid("6a1e3c52-9b47-4d2f-8e1a-0c5d7f3b9e34");
        public static readonly Guid V4Block = new Guid("6a1e3c52-9b47-4d2f-8e1a-0c5d7f3b9e35");
        public static readonly Guid V6Core = new Guid("6a1e3c52-9b47-4d2f-8e1a-0c5d7f3b9e41");
        public static readonly Guid V6Loopback = new Guid("6a1e3c52-9b47-4d2f-8e1a-0c5d7f3b9e42");
        public static readonly Guid V6Lan = new Guid("6a1e3c52-9b47-4d2f-8e1a-0c5d7f3b9e44");
        public static readonly Guid V6Block = new Guid("6a1e3c52-9b47-4d2f-8e1a-0c5d7f3b9e45");
        public static Guid[] AllKeys { get { return new Guid[] { V4Core, V4Loopback, V4Tun, V4Lan, V4Block, V6Core, V6Loopback, V6Lan, V6Block }; } }

        private const string SubLayerName = "Claude global kill switch v1";
        private const string FilterPrefix = "Claude global kill switch: ";
        private const ushort SubLayerWeight = 0x8002;
        private const uint PersistentFlag = 1, SessionDynamicFlag = 1;
        private const uint ActionBlock = 0x1001, ActionPermit = 0x1002, LoopbackFlag = 1;
        private const int MatchEqual = 0, MatchFlagsAllSet = 6;
        private const int TypeEmpty = 0, TypeUint8 = 1, TypeUint32 = 3, TypeByteBlob = 12, TypeV4AddrMask = 0x100, TypeV6AddrMask = 0x101;
        private const uint FilterNotFound = 0x80320003, SubLayerNotFound = 0x80320007, AccessDenied = 5;
        private const byte WeightPermit = 15, WeightBlock = 1;

        public static string ValidateAbi()
        {
            Size<DisplayData>(16); Size<ByteBlob>(16); Size<Value>(16); Size<FilterCondition>(40);
            Size<FilterAction>(20); Size<NativeFilter>(200); Size<NativeSubLayer>(72); Size<NativeSession>(72);
            Size<V4AddrMask>(8); Size<V6AddrMask>(17);
            Offset<NativeFilter>("LayerKey", 64); Offset<NativeFilter>("SubLayerKey", 80); Offset<NativeFilter>("Weight", 96);
            Offset<NativeFilter>("NumFilterConditions", 112); Offset<NativeFilter>("Conditions", 120);
            Offset<NativeFilter>("Action", 128); Offset<NativeFilter>("FilterId", 176);
            Offset<NativeSubLayer>("Weight", 64);
            Offset<NativeSession>("Flags", 32); Offset<NativeSession>("Sid", 48); Offset<NativeSession>("KernelMode", 64);
            return "Windows x64 ABI OK";
        }

        // 打开会话。dynamic=true 时本会话加的子层和过滤在句柄关闭（含进程退出）时由系统自动删除。
        public static KillSwitchSession Open(bool dynamic)
        {
            ValidateAbi();
            KillSwitchSession s = new KillSwitchSession { Dynamic = dynamic };
            if (dynamic)
            {
                NativeSession session = new NativeSession { Flags = SessionDynamicFlag };
                IntPtr p = Marshal.AllocHGlobal(Marshal.SizeOf(typeof(NativeSession)));
                try
                {
                    Marshal.StructureToPtr(session, p, false);
                    Check(Native.FwpmEngineOpen0(null, 10, IntPtr.Zero, p, out s.Handle), "Open dynamic WFP session");
                }
                finally { Marshal.FreeHGlobal(p); }
            }
            else
            {
                Check(Native.FwpmEngineOpen0(null, 10, IntPtr.Zero, IntPtr.Zero, out s.Handle), "Open WFP engine");
            }
            return s;
        }

        internal static void CloseEngine(IntPtr handle) { Native.FwpmEngineClose0(handle); }

        // 在一个事务里加子层和 9 条过滤；任何一步失败整体回滚，不会留下半套规则。
        public static KillSwitchFilterInfo[] Install(KillSwitchSession session, string[] corePaths, string tunCidr, string[] lanV4, string[] lanV6)
        {
            if (session == null || session.Handle == IntPtr.Zero) throw new ArgumentException("Open a session first.");
            if (corePaths == null || corePaths.Length == 0) throw new ArgumentException("At least one Clash core path is required.");
            bool persistent = !session.Dynamic;
            List<IntPtr> appIds = new List<IntPtr>();
            try
            {
                foreach (string path in corePaths)
                {
                    string full = ValidatePath(path);
                    IntPtr appId;
                    Check(Native.FwpmGetAppIdFromFileName0(full, out appId), "Get application ID for " + full);
                    appIds.Add(appId);
                }
                using (Arena arena = new Arena())
                {
                    IntPtr h = session.Handle;
                    bool transaction = false;
                    try
                    {
                        Check(Native.FwpmTransactionBegin0(h, 0), "Begin install transaction");
                        transaction = true;
                        EnsureSubLayer(h, arena, persistent);
                        // Clash 内核：它要直连节点（也负责直连规则的国内流量）
                        AddFilter(h, arena, V4Core, LayerV4, "permit Clash core v4", ActionPermit, WeightPermit, persistent, AppConditions(appIds));
                        AddFilter(h, arena, V6Core, LayerV6, "permit Clash core v6", ActionPermit, WeightPermit, persistent, AppConditions(appIds));
                        // 本机回环：43865/43866/43867 三个代理端口
                        AddFilter(h, arena, V4Loopback, LayerV4, "permit loopback v4", ActionPermit, WeightPermit, persistent, new FilterCondition[] { LoopbackCondition() });
                        AddFilter(h, arena, V6Loopback, LayerV6, "permit loopback v6", ActionPermit, WeightPermit, persistent, new FilterCondition[] { LoopbackCondition() });
                        // TUN：本机地址在 TUN 网段的连接（TUN 掉了这条就不再命中）
                        AddFilter(h, arena, V4Tun, LayerV4, "permit TUN " + tunCidr, ActionPermit, WeightPermit, persistent,
                            new FilterCondition[] { V4Condition(arena, LocalAddressKey, tunCidr) });
                        // 局域网：同一字段的多个条件是「或」
                        AddFilter(h, arena, V4Lan, LayerV4, "permit LAN v4", ActionPermit, WeightPermit, persistent, V4Conditions(arena, RemoteAddressKey, lanV4));
                        AddFilter(h, arena, V6Lan, LayerV6, "permit LAN v6", ActionPermit, WeightPermit, persistent, V6Conditions(arena, RemoteAddressKey, lanV6));
                        // 其余全部拦
                        AddFilter(h, arena, V4Block, LayerV4, "block everything else v4", ActionBlock, WeightBlock, persistent, new FilterCondition[0]);
                        AddFilter(h, arena, V6Block, LayerV6, "block everything else v6", ActionBlock, WeightBlock, persistent, new FilterCondition[0]);
                        KillSwitchFilterInfo[] result = ReadAll(h);
                        foreach (KillSwitchFilterInfo info in result)
                            if (info == null) throw new InvalidOperationException("A kill switch filter is missing after add.");
                        Check(Native.FwpmTransactionCommit0(h), "Commit install transaction");
                        transaction = false;
                        return result;
                    }
                    finally
                    {
                        if (transaction) Native.FwpmTransactionAbort0(h);
                    }
                }
            }
            finally
            {
                for (int i = 0; i < appIds.Count; i++) { IntPtr p = appIds[i]; Native.FwpmFreeMemory0(ref p); }
            }
        }

        // 只读：返回 9 条固定过滤的现状（不存在的位置为 null）。
        public static KillSwitchFilterInfo[] Status()
        {
            using (KillSwitchSession s = Open(false)) return ReadAll(s.Handle);
        }

        // 删除常驻安装的 9 条过滤和子层；只删固定 GUID 且名字带本开关前缀的。
        public static int Remove()
        {
            using (KillSwitchSession s = Open(false))
            {
                IntPtr h = s.Handle;
                bool transaction = false;
                try
                {
                    Check(Native.FwpmTransactionBegin0(h, 0), "Begin remove transaction");
                    transaction = true;
                    int removed = 0;
                    foreach (Guid key in AllKeys)
                    {
                        KillSwitchFilterInfo info = ReadFilter(h, key);
                        if (info == null) continue;
                        if (info.Name == null || !info.Name.StartsWith(FilterPrefix, StringComparison.Ordinal))
                            throw new InvalidOperationException("Refusing to remove a foreign filter: " + key);
                        Guid k = key;
                        Check(Native.FwpmFilterDeleteByKey0(h, ref k), "Delete filter " + key);
                        removed++;
                    }
                    Guid sub = SubLayerKey;
                    IntPtr p;
                    uint r = Native.FwpmSubLayerGetByKey0(h, ref sub, out p);
                    if (r == 0) { Native.FwpmFreeMemory0(ref p); Check(Native.FwpmSubLayerDeleteByKey0(h, ref sub), "Delete sublayer"); }
                    else if (r != SubLayerNotFound) Check(r, "Read sublayer");
                    Check(Native.FwpmTransactionCommit0(h), "Commit remove transaction");
                    transaction = false;
                    return removed;
                }
                finally
                {
                    if (transaction) Native.FwpmTransactionAbort0(h);
                }
            }
        }

        private static KillSwitchFilterInfo[] ReadAll(IntPtr h)
        {
            Guid[] keys = AllKeys;
            KillSwitchFilterInfo[] result = new KillSwitchFilterInfo[keys.Length];
            for (int i = 0; i < keys.Length; i++) result[i] = ReadFilter(h, keys[i]);
            return result;
        }

        private static KillSwitchFilterInfo ReadFilter(IntPtr engine, Guid key)
        {
            IntPtr pointer = IntPtr.Zero;
            uint result = Native.FwpmFilterGetByKey0(engine, ref key, out pointer);
            try
            {
                if (result == FilterNotFound) return null;
                // 常驻过滤装上后普通用户读详情会被拒（0x5）：能确定它存在，只是看不到内容。
                if (result == AccessDenied) return new KillSwitchFilterInfo { Key = key, Name = FilterPrefix + "(已安装，看详情需要管理员)", Persistent = true, AccessDenied = true };
                Check(result, "Read filter " + key);
                NativeFilter value = Marshal.PtrToStructure<NativeFilter>(pointer);
                return new KillSwitchFilterInfo {
                    Key = value.Key, Name = Marshal.PtrToStringUni(value.Display.Name),
                    Persistent = (value.Flags & PersistentFlag) != 0, Action = value.Action.Type, Id = value.FilterId
                };
            }
            finally { if (pointer != IntPtr.Zero) Native.FwpmFreeMemory0(ref pointer); }
        }

        private static void EnsureSubLayer(IntPtr engine, Arena arena, bool persistent)
        {
            Guid key = SubLayerKey;
            IntPtr p;
            uint r = Native.FwpmSubLayerGetByKey0(engine, ref key, out p);
            if (r == 0) { Native.FwpmFreeMemory0(ref p); return; }
            if (r != SubLayerNotFound) Check(r, "Read sublayer");
            NativeSubLayer value = new NativeSubLayer {
                Key = key,
                Display = new DisplayData { Name = arena.String(SubLayerName), Description = arena.String("Only Clash core, TUN, loopback and LAN may connect out.") },
                Flags = persistent ? PersistentFlag : 0, ProviderKey = IntPtr.Zero, Weight = SubLayerWeight
            };
            Check(Native.FwpmSubLayerAdd0(engine, ref value, IntPtr.Zero), "Add sublayer");
        }

        private static void AddFilter(IntPtr engine, Arena arena, Guid key, Guid layer, string name, uint action, byte weight,
            bool persistent, FilterCondition[] conditions)
        {
            if (ReadFilter(engine, key) != null) throw new InvalidOperationException("Filter already exists (remove first): " + name);
            int stride = Marshal.SizeOf(typeof(FilterCondition));
            IntPtr block = IntPtr.Zero;
            if (conditions.Length > 0)
            {
                block = arena.Allocate(checked(stride * conditions.Length));
                for (int i = 0; i < conditions.Length; i++) Marshal.StructureToPtr(conditions[i], IntPtr.Add(block, stride * i), false);
            }
            NativeFilter filter = new NativeFilter {
                Key = key,
                Display = new DisplayData { Name = arena.String(FilterPrefix + name), Description = arena.String(name) },
                Flags = persistent ? PersistentFlag : 0, ProviderKey = IntPtr.Zero,
                LayerKey = layer, SubLayerKey = SubLayerKey,
                Weight = new Value { Type = TypeUint8, Uint32 = weight },
                NumFilterConditions = (uint)conditions.Length, Conditions = block,
                Action = new FilterAction { Type = action }
            };
            ulong id;
            Check(Native.FwpmFilterAdd0(engine, ref filter, IntPtr.Zero, out id), "Add filter " + name);
        }

        private static FilterCondition[] AppConditions(List<IntPtr> appIds)
        {
            FilterCondition[] c = new FilterCondition[appIds.Count];
            for (int i = 0; i < appIds.Count; i++)
                c[i] = new FilterCondition { FieldKey = AppIdKey, MatchType = MatchEqual, ConditionValue = new Value { Type = TypeByteBlob, Pointer = appIds[i] } };
            return c;
        }

        private static FilterCondition LoopbackCondition()
        {
            return new FilterCondition { FieldKey = FlagsKey, MatchType = MatchFlagsAllSet, ConditionValue = new Value { Type = TypeUint32, Uint32 = LoopbackFlag } };
        }

        private static FilterCondition[] V4Conditions(Arena arena, Guid field, string[] cidrs)
        {
            FilterCondition[] c = new FilterCondition[cidrs.Length];
            for (int i = 0; i < cidrs.Length; i++) c[i] = V4Condition(arena, field, cidrs[i]);
            return c;
        }

        private static FilterCondition V4Condition(Arena arena, Guid field, string cidr)
        {
            string[] parts = cidr.Split('/');
            byte[] b = System.Net.IPAddress.Parse(parts[0]).GetAddressBytes();
            if (b.Length != 4) throw new ArgumentException("IPv4 CIDR expected: " + cidr);
            int prefix = int.Parse(parts[1]);
            if (prefix < 0 || prefix > 32) throw new ArgumentException("Bad prefix: " + cidr);
            uint addr = ((uint)b[0] << 24) | ((uint)b[1] << 16) | ((uint)b[2] << 8) | b[3]; // 主机字节序
            uint mask = prefix == 0 ? 0u : uint.MaxValue << (32 - prefix);
            IntPtr p = arena.Allocate(Marshal.SizeOf(typeof(V4AddrMask)));
            Marshal.StructureToPtr(new V4AddrMask { Addr = addr & mask, Mask = mask }, p, false);
            return new FilterCondition { FieldKey = field, MatchType = MatchEqual, ConditionValue = new Value { Type = TypeV4AddrMask, Pointer = p } };
        }

        private static FilterCondition[] V6Conditions(Arena arena, Guid field, string[] cidrs)
        {
            FilterCondition[] c = new FilterCondition[cidrs.Length];
            for (int i = 0; i < cidrs.Length; i++)
            {
                string[] parts = cidrs[i].Split('/');
                byte[] b = System.Net.IPAddress.Parse(parts[0]).GetAddressBytes();
                if (b.Length != 16) throw new ArgumentException("IPv6 CIDR expected: " + cidrs[i]);
                byte prefix = byte.Parse(parts[1]);
                if (prefix > 128) throw new ArgumentException("Bad prefix: " + cidrs[i]);
                IntPtr p = arena.Allocate(Marshal.SizeOf(typeof(V6AddrMask)));
                Marshal.Copy(b, 0, p, 16);
                Marshal.WriteByte(p, 16, prefix);
                c[i] = new FilterCondition { FieldKey = field, MatchType = MatchEqual, ConditionValue = new Value { Type = TypeV6AddrMask, Pointer = p } };
            }
            return c;
        }

        private static string ValidatePath(string path)
        {
            if (String.IsNullOrWhiteSpace(path) || path.IndexOfAny(new char[] { '*', '?', '\0' }) >= 0)
                throw new ArgumentException("Absolute EXE path required: " + path);
            string full = Path.GetFullPath(path);
            if (!String.Equals(Path.GetExtension(full), ".exe", StringComparison.OrdinalIgnoreCase) || !File.Exists(full))
                throw new ArgumentException("EXE not found: " + full);
            return full;
        }

        private static void Check(uint result, string operation)
        {
            if (result != 0) throw new InvalidOperationException(operation + " failed: 0x" + result.ToString("X8"));
        }
        private static void Size<T>(int expected)
        {
            int actual = Marshal.SizeOf(typeof(T));
            if (actual != expected) throw new PlatformNotSupportedException(typeof(T).Name + " ABI size " + actual + " != " + expected);
        }
        private static void Offset<T>(string field, int expected)
        {
            long actual = Marshal.OffsetOf(typeof(T), field).ToInt64();
            if (actual != expected) throw new PlatformNotSupportedException(typeof(T).Name + "." + field + " offset " + actual + " != " + expected);
        }

        private sealed class Arena : IDisposable
        {
            private readonly List<IntPtr> allocations = new List<IntPtr>();
            internal IntPtr Allocate(int size)
            {
                IntPtr pointer = Marshal.AllocHGlobal(size);
                allocations.Add(pointer);
                Marshal.Copy(new byte[size], 0, pointer, size);
                return pointer;
            }
            internal IntPtr String(string value)
            {
                IntPtr pointer = Marshal.StringToHGlobalUni(value);
                allocations.Add(pointer);
                return pointer;
            }
            public void Dispose()
            {
                for (int i = allocations.Count - 1; i >= 0; i--) Marshal.FreeHGlobal(allocations[i]);
                allocations.Clear();
            }
        }

        [StructLayout(LayoutKind.Sequential)] private struct DisplayData { public IntPtr Name; public IntPtr Description; }
        [StructLayout(LayoutKind.Sequential)] private struct ByteBlob { public uint Size; public IntPtr Data; }
        [StructLayout(LayoutKind.Explicit, Size = 16)]
        private struct Value { [FieldOffset(0)] public int Type; [FieldOffset(8)] public uint Uint32; [FieldOffset(8)] public IntPtr Pointer; }
        [StructLayout(LayoutKind.Sequential)] private struct FilterCondition { public Guid FieldKey; public int MatchType; public Value ConditionValue; }
        [StructLayout(LayoutKind.Sequential)] private struct FilterAction { public uint Type; public Guid FilterType; }
        [StructLayout(LayoutKind.Explicit, Size = 16)]
        private struct FilterContext { [FieldOffset(0)] public ulong RawContext; [FieldOffset(0)] public Guid ProviderContextKey; }
        [StructLayout(LayoutKind.Sequential)]
        private struct NativeFilter {
            public Guid Key; public DisplayData Display; public uint Flags; public IntPtr ProviderKey;
            public ByteBlob ProviderData; public Guid LayerKey; public Guid SubLayerKey; public Value Weight;
            public uint NumFilterConditions; public IntPtr Conditions; public FilterAction Action;
            public FilterContext Context; public IntPtr Reserved; public ulong FilterId; public Value EffectiveWeight;
        }
        [StructLayout(LayoutKind.Sequential)]
        private struct NativeSubLayer {
            public Guid Key; public DisplayData Display; public uint Flags; public IntPtr ProviderKey;
            public ByteBlob ProviderData; public ushort Weight;
        }
        [StructLayout(LayoutKind.Sequential)]
        private struct NativeSession {
            public Guid SessionKey; public DisplayData Display; public uint Flags; public uint TxnWaitTimeoutInMSec;
            public uint ProcessId; public IntPtr Sid; public IntPtr Username; public int KernelMode;
        }
        [StructLayout(LayoutKind.Sequential)] private struct V4AddrMask { public uint Addr; public uint Mask; }
        [StructLayout(LayoutKind.Sequential, Size = 17)] private struct V6AddrMask { [MarshalAs(UnmanagedType.ByValArray, SizeConst = 16)] public byte[] Addr; public byte PrefixLength; }

        private static class Native
        {
            private const string Dll = "fwpuclnt.dll";
            [DllImport(Dll, ExactSpelling = true, CharSet = CharSet.Unicode)]
            internal static extern uint FwpmEngineOpen0(string serverName, uint authenticationService, IntPtr authenticationIdentity, IntPtr session, out IntPtr engine);
            [DllImport(Dll, ExactSpelling = true)] internal static extern uint FwpmEngineClose0(IntPtr engine);
            [DllImport(Dll, ExactSpelling = true)] internal static extern uint FwpmTransactionBegin0(IntPtr engine, uint flags);
            [DllImport(Dll, ExactSpelling = true)] internal static extern uint FwpmTransactionCommit0(IntPtr engine);
            [DllImport(Dll, ExactSpelling = true)] internal static extern uint FwpmTransactionAbort0(IntPtr engine);
            [DllImport(Dll, ExactSpelling = true, CharSet = CharSet.Unicode)]
            internal static extern uint FwpmGetAppIdFromFileName0(string fileName, out IntPtr appId);
            [DllImport(Dll, ExactSpelling = true)] internal static extern void FwpmFreeMemory0(ref IntPtr memory);
            [DllImport(Dll, ExactSpelling = true)] internal static extern uint FwpmSubLayerAdd0(IntPtr engine, ref NativeSubLayer subLayer, IntPtr securityDescriptor);
            [DllImport(Dll, ExactSpelling = true)] internal static extern uint FwpmSubLayerGetByKey0(IntPtr engine, ref Guid key, out IntPtr subLayer);
            [DllImport(Dll, ExactSpelling = true)] internal static extern uint FwpmSubLayerDeleteByKey0(IntPtr engine, ref Guid key);
            [DllImport(Dll, ExactSpelling = true)] internal static extern uint FwpmFilterAdd0(IntPtr engine, ref NativeFilter filter, IntPtr securityDescriptor, out ulong id);
            [DllImport(Dll, ExactSpelling = true)] internal static extern uint FwpmFilterGetByKey0(IntPtr engine, ref Guid key, out IntPtr filter);
            [DllImport(Dll, ExactSpelling = true)] internal static extern uint FwpmFilterDeleteByKey0(IntPtr engine, ref Guid key);
        }
    }
}
