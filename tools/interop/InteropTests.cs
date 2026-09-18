using System.Diagnostics;
using System.Security.Cryptography;

sealed class JavaPhone : IAuthLink, IDisposable {
    readonly Process process;
    public string? LastAuth;
    public Func<string,string>? Transform;
    public JavaPhone(string classes, string hosts, string result, bool pair) {
        var start = new ProcessStartInfo("java") { RedirectStandardInput=true, RedirectStandardOutput=true, UseShellExecute=false };
        foreach (string arg in new[]{"-cp", classes, "PhoneHarness", hosts, result, pair.ToString().ToLowerInvariant()}) start.ArgumentList.Add(arg);
        process=Process.Start(start)!;
    }
    public string Exchange(string request) {
        if (request.StartsWith("AUTH2 ")) LastAuth=request;
        request=Transform?.Invoke(request) ?? request;
        process.StandardInput.WriteLine(request); process.StandardInput.Flush();
        return process.StandardOutput.ReadLineAsync().WaitAsync(TimeSpan.FromSeconds(10)).GetAwaiter().GetResult()
            ?? throw new IOException("Java phone exited");
    }
    public void Dispose() { process.StandardInput.Close(); if (!process.WaitForExit(2000)) process.Kill(true); process.Dispose(); }
}

static class InteropTests {
    static void Require(bool ok, string label) { if (!ok) throw new Exception(label); Console.WriteLine("PASS " + label); }
    public static void Main(string[] args) {
        string root=Path.Combine(Path.GetTempPath(),"usbmanager-interop-"+Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        string hosts=Path.Combine(root,"hosts"), result=Path.Combine(root,"result");
        using var identity=ECDsa.Create(ECCurve.NamedCurves.nistP256);
        using(var phone=new JavaPhone(args[0],hosts,result,false)) {
            Require(Protocol.Authenticate(phone,identity,"测试电脑").StartsWith("UNKNOWN "),"closed pairing returns UNKNOWN");
            Require(!Directory.EnumerateFiles(hosts).Any(),"closed pairing stores no host");
        }
        using(var phone=new JavaPhone(args[0],hosts,result,true)) {
            Require(Protocol.Authenticate(phone,identity,"测试电脑").StartsWith("PAIRED "),"C# -> Java ECDH/HKDF/signature/AES-GCM pairing");
            Require(File.ReadAllText(result).StartsWith("PAIRED|") && File.ReadAllText(result).TrimEnd().EndsWith("|mtp|false"),"durable phone result and profile");
            Require(phone.Exchange(phone.LastAuth!)=="ERROR2 CHALLENGE","AUTH2 replay rejected");
        }
        using(var phone=new JavaPhone(args[0],hosts,result,false))
            Require(Protocol.Authenticate(phone,identity,"测试电脑").StartsWith("KNOWN "),"restarted daemon recognizes persisted identity");
        using var stranger=ECDsa.Create(ECCurve.NamedCurves.nistP256);
        int count=Directory.GetFiles(hosts,"*.properties").Length;
        using(var phone=new JavaPhone(args[0],hosts,result,true)) {
            phone.Transform=request=>{
                if(!request.StartsWith("AUTH2 "))return request;
                var f=request.Split(' '); var bytes=Convert.FromBase64String(f[3]);bytes[^1]^=1;f[3]=Convert.ToBase64String(bytes);return string.Join(' ',f);
            };
            bool rejected=false;
            try { Protocol.Authenticate(phone,stranger,"tampered"); } catch(IOException){rejected=true;}
            Require(rejected && Directory.GetFiles(hosts,"*.properties").Length==count,"tampered GCM tag rejected without storing host");
        }
        Console.WriteLine("Test artifacts: " + root);
    }
}
