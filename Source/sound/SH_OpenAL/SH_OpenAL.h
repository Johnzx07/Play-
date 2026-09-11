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
		//Number of buffers to queue up before letting the source play. Starting
		//with a single buffer leaves no margin: one late update and the source
		//runs dry again immediately.
		PLAYBACK_START_BUFFERS = 4,
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
	uint32 m_queuedBufferCount = 0;
	uint64 m_lastUpdateTime;
	bool m_mustSync;
	ALuint m_bufferNames[MAX_BUFFERS];
};
