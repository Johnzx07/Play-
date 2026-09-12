#include "SH_OpenAL.h"
#include "alloca_def.h"
#include <assert.h>

//#define LOGGING
#define SAMPLE_RATE 44100

ALCint g_attrList[] =
    {
        ALC_FREQUENCY, SAMPLE_RATE,
        0, 0};

#define CHECK_AL_ERROR()                     \
	{                                        \
		assert(alGetError() == AL_NO_ERROR); \
	}

CSH_OpenAL::CSH_OpenAL()
    : m_context(m_device, g_attrList)
    , m_lastUpdateTime(0)
    , m_mustSync(true)
{
	m_context.MakeCurrent();
	alGenBuffers(MAX_BUFFERS, m_bufferNames);
	CHECK_AL_ERROR();
	Reset();
}

CSH_OpenAL::~CSH_OpenAL()
{
	Reset();
	alDeleteBuffers(MAX_BUFFERS, m_bufferNames);
	CHECK_AL_ERROR();
}

CSoundHandler* CSH_OpenAL::HandlerFactory()
{
	return new CSH_OpenAL();
}

void CSH_OpenAL::Reset()
{
	m_source.Stop();
	ALint sourceState = m_source.GetState();
	assert(sourceState == AL_INITIAL || sourceState == AL_STOPPED);
	alSourcei(m_source, AL_BUFFER, 0);
	CHECK_AL_ERROR();
	m_startingPlayback = false;
	m_availableBuffers.clear();
	m_availableBuffers.insert(m_availableBuffers.begin(), m_bufferNames, m_bufferNames + MAX_BUFFERS);
}

void CSH_OpenAL::RecycleBuffers()
{
	if(m_startingPlayback)
	{
		//A source that isn't playing reports everything queued on it as
		//processed, even buffers it has never played, so recycling here would
		//hand back the very blocks we're stacking up to start playback with.
		//Write() clears this as soon as the source is started.
		return;
	}

	unsigned int bufferCount = m_source.GetBuffersProcessed();
	CHECK_AL_ERROR();
	if(bufferCount != 0)
	{
		ALuint* bufferNames = reinterpret_cast<ALuint*>(alloca(sizeof(ALuint) * bufferCount));
		alSourceUnqueueBuffers(m_source, bufferCount, bufferNames);
		CHECK_AL_ERROR();
		m_availableBuffers.insert(m_availableBuffers.begin(), bufferNames, bufferNames + bufferCount);
	}
}

bool CSH_OpenAL::HasFreeBuffers()
{
	return m_availableBuffers.size() != 0;
}

uint32 CSH_OpenAL::GetFreeBufferCount() const
{
	return m_availableBuffers.size();
}

void CSH_OpenAL::Write(int16* samples, unsigned int sampleCount, unsigned int sampleRate)
{
	assert(m_availableBuffers.size() != 0);
	if(m_availableBuffers.size() == 0) return;
	ALuint buffer = *m_availableBuffers.begin();
	m_availableBuffers.pop_front();

	alBufferData(buffer, AL_FORMAT_STEREO16, samples, sampleCount * sizeof(int16), sampleRate);
	CHECK_AL_ERROR();

	alSourceQueueBuffers(m_source, 1, &buffer);
	CHECK_AL_ERROR();

	ALint sourceState = m_source.GetState();
	if(sourceState == AL_PLAYING)
	{
		m_startingPlayback = false;
		return;
	}

	//Stack up a few blocks before starting, so a hitch in the emulation thread
	//doesn't immediately drain the source. RecycleBuffers() leaves the queue
	//alone while this is set.
	m_startingPlayback = true;

	ALint queuedBufferCount = 0;
	alGetSourcei(m_source, AL_BUFFERS_QUEUED, &queuedBufferCount);
	CHECK_AL_ERROR();

	//Start once we have our cushion. The second condition is what makes this
	//safe rather than clever: whatever the queue accounting says, we always
	//start before the pool runs out, so waiting here can never turn into
	//permanent silence.
	bool poolRunningLow = (m_availableBuffers.size() <= PLAYBACK_START_BUFFERS);
	if((queuedBufferCount >= PLAYBACK_START_BUFFERS) || poolRunningLow)
	{
		m_source.Play();
		assert(m_source.GetState() == AL_PLAYING);
		m_startingPlayback = false;
	}
}
