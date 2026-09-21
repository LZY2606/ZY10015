// eng/tools/PackageInspector.cs - file-based program (dotnet <file>, no restore/project).
// Audits NuGet packages produced by eng/verify.core.sh, rewrites them into a canonical
// form (sorted entries, fixed timestamps/ids) and emits SHA256 hashes.
using System.Security.Cryptography;
using System.Text;
using System.IO.Compression;

if (args.Length != 4)
{
    Console.Error.WriteLine("usage: dotnet <this-file> <dummy> audit <package-root> <normalized-output> <repo-root>");
    return 2;
}

var packageRoot = Path.GetFullPath(args[^3]);
var normalizedRoot = Path.GetFullPath(args[^2]);
var repoRoot = Path.GetFullPath(args[^1]).Replace('\\', '/').TrimEnd('/');
Directory.CreateDirectory(normalizedRoot);

string[] packageFiles = Directory.GetFiles(packageRoot, "*.nupkg", new EnumerationOptions { RecurseSubdirectories = true });
if (packageFiles.Length == 0)
{
    Console.Error.WriteLine($"ERROR: no .nupkg files found under {packageRoot}");
    return 3;
}

// Entry order makes relationship and core-properties parts deterministic.
static int EntryRank(string name)
{
    if (name == "[Content_Types].xml") return 0;
    if (name == "_rels/.rels") return 1;
    if (name.EndsWith(".psmdcp", StringComparison.Ordinal)) return 2;
    if (name.EndsWith(".nuspec", StringComparison.Ordinal)) return 3;
    return 4;
}

var forbiddenParts = new[] { "/test/", "/tests/", "/example/", "/examples/", "/playground/", "/benchmark" };
var manifest = new SortedDictionary<string, string>();
int errors = 0;

foreach (var packageFile in packageFiles.OrderBy(Path.GetFileName))
{
    using var input = ZipFile.OpenRead(packageFile);
    var entries = input.Entries
        .Where(e => !string.IsNullOrEmpty(e.Name))
        .OrderBy(e => e.Name, StringComparer.Ordinal)
        .OrderBy(e => EntryRank(e.Name))
        .ToList();

    foreach (var entry in entries)
    {
        var name = entry.FullName.Replace('\\', '/');
        var lowered = "/" + name.ToLowerInvariant();
        if (name.EndsWith(".log", StringComparison.OrdinalIgnoreCase) ||
            forbiddenParts.Any(p => lowered.Contains(p, StringComparison.Ordinal)))
        {
            Console.Error.WriteLine($"FORBIDDEN entry {Path.GetFileName(packageFile)} :: {name}");
            errors++;
        }

        if (!name.EndsWith('/'))
        {
            using var reader = new StreamReader(entry.Open());
            var text = reader.ReadToEnd();
            if (text.Contains(repoRoot, StringComparison.Ordinal))
            {
                Console.Error.WriteLine($"ABSOLUTE PATH in {Path.GetFileName(packageFile)} :: {name}");
                errors++;
            }
        }
    }

    var packageDirName = Path.GetDirectoryName(packageFile);
    var outDir = Path.Combine(normalizedRoot,
        packageDirName is null ? string.Empty : Path.GetFileName(packageDirName));
    Directory.CreateDirectory(outDir);
    var normalizedPath = Path.Combine(outDir, Path.GetFileName(packageFile));
    using (var output = new ZipArchive(File.Create(normalizedPath), ZipArchiveMode.Create))
    {
        var corePropertiesPath = entries
            .Select(e => e.FullName)
            .FirstOrDefault(n => n.StartsWith("package/services/metadata/core-properties/", StringComparison.Ordinal)
                                 && n.EndsWith(".psmdcp", StringComparison.Ordinal));

        foreach (var entry in entries)
        {
            var sourceName = entry.FullName.TrimStart('/');
            var name = sourceName;
            if (corePropertiesPath != null && name == corePropertiesPath.TrimStart('/'))
            {
                name = "package/services/metadata/core-properties/core.psmdcp";
            }
            var data = ReadFixed(entry, sourceName, corePropertiesPath?.TrimStart('/'));
            var item = output.CreateEntry(name, System.IO.Compression.CompressionLevel.Optimal);
            item.LastWriteTime = new DateTime(1980, 1, 1, 0, 0, 0, DateTimeKind.Utc);
            item.ExternalAttributes = entry.ExternalAttributes;
            using var entryStream = item.Open();
            entryStream.Write(data);
        }
    }

    var hash = Convert.ToHexString(SHA256.HashData(File.ReadAllBytes(normalizedPath))).ToLowerInvariant();
    manifest[Path.GetRelativePath(packageRoot, normalizedPath)] = hash;
    Console.WriteLine($"audited {Path.GetFileName(packageFile),-44} sha256 {hash}");
}

var lines = manifest.Select(kv => $"{kv.Value}  {kv.Key}");
File.WriteAllLines(Path.Combine(packageRoot, "..", "packages.sha256"), lines.OrderBy(l => l, StringComparer.Ordinal));

if (errors > 0)
{
    Console.Error.WriteLine($"ERROR: package audit failed with {errors} violation(s)");
    return 4;
}

return 0;

static byte[] ReadFixed(ZipArchiveEntry entry, string name, string? corePropertiesPath)
{
    using var source = entry.Open();
    using var memory = new MemoryStream();
    source.CopyTo(memory);
    var data = memory.ToArray();

    if (name == "_rels/.rels")
    {
        var text = System.Text.Encoding.UTF8.GetString(data);
        var fixedText = System.Text.RegularExpressions.Regex.Replace(
            text,
            " Id=\"[^\"]+\"",
            " Id=\"R0000000000000000000000000000000\"");
        if (corePropertiesPath != null)
        {
            var corePropertiesFile = corePropertiesPath.Replace('\\', '/').Split('/')[^1];
            fixedText = fixedText.Replace(
                $"Target=\"/package/services/metadata/core-properties/{corePropertiesFile}\"",
                "Target=\"/package/services/metadata/core-properties/core.psmdcp\"");
        }
        data = System.Text.Encoding.UTF8.GetBytes(fixedText);
    }
    else if (corePropertiesPath != null && name == corePropertiesPath)
    {
        var text = System.Text.Encoding.UTF8.GetString(data);
        text = System.Text.RegularExpressions.Regex.Replace(
            text,
            "</dcterms:(created|modified|lastPrinted)>.*?</dcterms:\\1>",
            "<dcterms:${1}>2000-01-01T00:00:00Z</dcterms:${1}>");
        text = System.Text.RegularExpressions.Regex.Replace(text, "\\s+xsi:type=\"dcterms:W3CDTF\"[^/]*/", string.Empty);
        data = System.Text.Encoding.UTF8.GetBytes(text);
    }

    return data;
}
