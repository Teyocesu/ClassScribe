using ClassScribe.Core;

namespace ClassScribe.Core.Tests;

[TestClass]
public sealed class PcmWaveFileTests
{
    [TestMethod]
    public async Task readPcmTailStartsAtRequestedFrame()
    {
        var path = Path.Combine(Path.GetTempPath(), $"classscribe-wave-{Guid.NewGuid():N}.wav");
        var pcm = new byte[PcmWaveFile.SampleRate * 2 * 3];
        for (var index = 0; index < pcm.Length; index++)
        {
            pcm[index] = checked((byte)(index % 251));
        }

        try
        {
            await using (var output = File.Create(path))
            await using (var wave = PcmWaveFile.CreateWaveStream(pcm))
            {
                await wave.CopyToAsync(output);
            }

            var tail = await PcmWaveFile.ReadPcmTailAsync(path, 1.5);

            Assert.AreEqual(pcm.Length / 2, tail.Length);
            CollectionAssert.AreEqual(pcm[(pcm.Length / 2)..], tail);
        }
        finally
        {
            File.Delete(path);
        }
    }
}
