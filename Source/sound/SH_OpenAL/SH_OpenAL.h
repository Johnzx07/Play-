#pragma once

#include <deque>
#include "../SoundHandler.h"
#include "openal/Device.h"
#include "openal/Context.h"
#include "openal/Source.h"
#include "openal/Buffer.h"

class CSH_OpenAL : public CSoundHandler
{
public:
	enum
	{
		MAX_BUFFERS = 25,
		//Number of buffers to queue on the source before letting it play.
		//Playback starting with a single buffer queued leaves no slack at all:
		//the emulation thread has to hand over the next block within exactly
		//one block's worth of wall clock time or the source runs dry and stops,
		//which is audible as a click. Each extra buffer here buys one block of
		//tolerance at the cost of one block of output latency.
		PLAYBACK_START_BUFFERS = 2,
	};

	CSH_OpenAL();
	virtual ~CSH_OpenAL();

	static CSoundHandler* HandlerFactory();

	void Reset() override;
	void Write(int16*, unsigned int, unsigned int) override;
	bool HasFreeBuffers() override;
	void RecycleBuffers() override;

	uint32 GetFreeBufferCount() const;

private:
	typedef std::deque<ALuint> BufferList;

	OpenAl::CDevice m_device;
	OpenAl::CContext m_context;
	OpenAl::CSource m_source;

	BufferList m_availableBuffers;
	uint64 m_lastUpdateTime;
	bool m_mustSync;
	bool m_startingPlayback = false;
	ALuint m_bufferNames[MAX_BUFFERS];
};
