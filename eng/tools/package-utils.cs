// Deterministic NuGet package utilities used by eng/verify.sh.
// Runs as a .NET 10 file-based app; no external packages required (offline safe).
//
// Usage:
//   dotnet run eng/tools/package-utils.cs -- normalize <packagesDir>
//   dotnet run eng/tools/package-utils.cs -- check <packagesDir> <repoRoot>

using System.IO.Compression;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;

if (args.Length < 2)
{
    Console.Error.WriteLine("usage: package-utils.cs -- normalize <dir> | check <dir> <repoRoot>");
    return 2;
}

var command = args[0];
var packagesDir = Path.GetFullPath(args[1]);

switch (command)
{
    case "normalize":
        return Normalize(packagesDir);
    case "check":
        if (args.Length < 3)
        {
            Console.Error.WriteLine("check requires <repoRoot>");
            return 2;
        }
        return Check(packagesDir, Path.GetFullPath(args[2]));
    default:
        Console.Error.WriteLine($"unknown command: {command}");
        return 2;
}

static int Normalize(string dir)
{
    var packages = Directory.GetFiles(dir, "*.nupkg").Concat(Directory.GetFiles(dir, "*.snupkg")).ToArray();
    if (packages.Length == 0)
    {
        Console.Error.WriteLine($"no packages found in {dir}");
        return 1;
    }

    foreach (var package in packages)
    {
        var entries = new List<(string Name, byte[] Data)>();
        using (var archive = ZipFile.OpenRead(package))
        {
            foreach (var entry in archive.Entries)
            {
                using var stream = entry.Open();
                using var memory = new MemoryStream();
                stream.CopyTo(memory);
                entries.Add((entry.FullName.Replace('\\', '/'), memory.ToArray()));
            }
        }

        // NuGet emits core-properties parts with random GUID names and random
        // relationship ids, which makes consecutive packs byte-different.
        // Rename them deterministically from their content and rewrite .rels.
        var renames = new Dictionary<string, string>(StringComparer.Ordinal);
        for (var i = 0; i < entries.Count; i++)
        {
            var (name, data) = entries[i];
            if (!name.EndsWith(".psmdcp", StringComparison.OrdinalIgnoreCase))
            {
                continue;
            }

            var directory = Path.GetDirectoryName(name)!.Replace('\\', '/');
            var hash = Convert.ToHexString(SHA256.HashData(data)).ToLowerInvariant();
            var renamed = $"{directory}/{hash}.psmdcp";
            renames[name] = renamed;
            entries[i] = (renamed, data);
        }

        for (var i = 0; i < entries.Count; i++)
        {
            var (name, data) = entries[i];
            if (!name.Equals("_rels/.rels", StringComparison.OrdinalIgnoreCase))
            {
                continue;
            }

            var xml = Encoding.UTF8.GetString(data);
            xml = Regex.Replace(xml, "<Relationship\\b[^>]*/?>", match =>
            {
                var element = match.Value;
                foreach (var (oldName, newName) in renames)
                {
                    element = element.Replace(
                        $"Target=\"/{oldName}\"", $"Target=\"/{newName}\"", StringComparison.Ordinal);
                }

                var targetMatch = Regex.Match(element, "Target=\"([^\"]*)\"");
                if (targetMatch.Success)
                {
                    var idBytes = SHA256.HashData(Encoding.UTF8.GetBytes(targetMatch.Groups[1].Value));
                    var id = "R" + Convert.ToHexString(idBytes)[..15];
                    element = Regex.Replace(element, "Id=\"[^\"]*\"", $"Id=\"{id}\"");
                }

                return element;
            });
            entries[i] = (name, Encoding.UTF8.GetBytes(xml));
        }

        var temp = package + ".tmp";
        using (var fileStream = File.Create(temp))
        using (var archive = new ZipArchive(fileStream, ZipArchiveMode.Create))
        {
            foreach (var (name, data) in entries.OrderBy(e => e.Name, StringComparer.Ordinal))
            {
                var entry = archive.CreateEntry(name, CompressionLevel.Optimal);
                entry.LastWriteTime = new DateTimeOffset(1980, 1, 1, 0, 0, 0, TimeSpan.Zero);
                using var stream = entry.Open();
                stream.Write(data);
            }
        }

        File.Move(temp, package, overwrite: true);
        Console.WriteLine($"normalized {Path.GetFileName(package)}");
    }

    return 0;
}

static int Check(string dir, string repoRoot)
{
    var packages = Directory.GetFiles(dir, "*.nupkg").Concat(Directory.GetFiles(dir, "*.snupkg"))
        .OrderBy(p => p, StringComparer.Ordinal)
        .ToArray();
    if (packages.Length == 0)
    {
        Console.Error.WriteLine($"no packages found in {dir}");
        return 1;
    }

    var failures = new List<string>();
    var forbiddenEntry = new Regex(
        @"(^|/)(test|tests|example|examples|samples?)(/|\.|$)|\.(log|tmp|bak)$|^/|^[A-Za-z]:|\.\.",
        RegexOptions.IgnoreCase | RegexOptions.Compiled);
    var absolutePath = new Regex(
        @"(/Users/|/home/|/root/|[A-Za-z]:[\\/]Users[\\/])",
        RegexOptions.Compiled);
    var repoRootBytes = Encoding.UTF8.GetBytes(repoRoot);

    foreach (var package in packages)
    {
        var name = Path.GetFileName(package);
        using var archive = ZipFile.OpenRead(package);
        foreach (var entry in archive.Entries)
        {
            var entryName = entry.FullName.Replace('\\', '/');
            if (forbiddenEntry.IsMatch(entryName))
            {
                failures.Add($"{name}: forbidden entry '{entryName}' (test/example/temp-log/absolute path)");
            }

            using var stream = entry.Open();
            using var memory = new MemoryStream();
            stream.CopyTo(memory);
            var bytes = memory.ToArray();
            var text = Encoding.Latin1.GetString(bytes);
            if (absolutePath.IsMatch(text))
            {
                failures.Add($"{name}: entry '{entryName}' contains an absolute path");
            }
            if (Contains(bytes, repoRootBytes))
            {
                failures.Add($"{name}: entry '{entryName}' contains the repo path '{repoRoot}'");
            }
        }
    }

    if (failures.Count > 0)
    {
        foreach (var failure in failures)
        {
            Console.Error.WriteLine($"package-check FAILED: {failure}");
        }
        return 1;
    }

    var sumsFile = Path.Combine(dir, "SHA256SUMS.txt");
    var lines = new List<string>();
    foreach (var package in packages)
    {
        var hash = Convert.ToHexString(SHA256.HashData(File.ReadAllBytes(package))).ToLowerInvariant();
        lines.Add($"{hash}  {Path.GetFileName(package)}");
    }

    File.WriteAllLines(sumsFile, lines);
    var manifestHash = Convert.ToHexString(
        SHA256.HashData(Encoding.UTF8.GetBytes(string.Join('\n', lines) + "\n"))).ToLowerInvariant();
    File.WriteAllText(Path.Combine(dir, "SHA256SUMS.txt.sha256"), manifestHash + "\n");

    foreach (var line in lines)
    {
        Console.WriteLine(line);
    }
    Console.WriteLine($"manifest-sha256 {manifestHash}");
    Console.WriteLine($"package-check OK: {packages.Length} packages, no test/example/temp-log/absolute paths");
    return 0;
}

static bool Contains(byte[] haystack, byte[] needle)
{
    if (needle.Length == 0 || haystack.Length < needle.Length)
    {
        return false;
    }

    for (var i = 0; i <= haystack.Length - needle.Length; i++)
    {
        var match = true;
        for (var j = 0; j < needle.Length; j++)
        {
            if (haystack[i + j] != needle[j])
            {
                match = false;
                break;
            }
        }
        if (match)
        {
            return true;
        }
    }
    return false;
}
