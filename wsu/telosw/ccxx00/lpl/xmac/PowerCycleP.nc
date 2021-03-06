/*
 * Copyright (c) 2005-2006 Rincon Research Corporation
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * - Redistributions of source code must retain the above copyright
 *   notice, this list of conditions and the following disclaimer.
 * - Redistributions in binary form must reproduce the above copyright
 *   notice, this list of conditions and the following disclaimer in the
 *   documentation and/or other materials provided with the
 *   distribution.
 * - Neither the name of the Rincon Research Corporation nor the names of
 *   its contributors may be used to endorse or promote products derived
 *   from this software without specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
 * ``AS IS'' AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
 * LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS
 * FOR A PARTICULAR PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL THE
 * RINCON RESEARCH OR ITS CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT,
 * INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
 * (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
 * SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
 * HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT,
 * STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED
 * OF THE POSSIBILITY OF SUCH DAMAGE
 */

/**
 * This module performs packet-based receive checks.  During a receive
 * check, the radio is left on for a certain amount of time.  If nothing
 * occurs in that amount of time, the radio turns off. Packet-based receive 
 * checks are very inefficient compared to energy-based receive checks, but
 * it offers high reliability and high throughput.
 * 
 * @author David Moss
 */
 
#include "PowerCycle.h"
#include "Blaze.h"

module PowerCycleP {
  provides {
    interface Init;
    interface PowerCycle[radio_id_t radioId];
    interface SplitControl[radio_id_t radioId];
    interface Receive[radio_id_t radioId];
    interface Send[radio_id_t radioId];
  }

  uses {
    interface Send as SubSend[radio_id_t radioId];
    interface Receive as SubReceive[radio_id_t radioId];
    interface SplitControl as SubControl[radio_id_t radioId];
    
    interface Timer<TMilli> as OnTimer;
    interface Timer<TMilli> as OffTimer;
    
    interface State as RadioPowerState;
    interface State as SplitControlState;
    interface State as SendState;
    
    interface GpioInterrupt as RxInterrupt[radio_id_t radioId];
    
    interface Leds;


  }
}

implementation {
  
  /** The current period of the duty cycle, equivalent of wakeup interval */
  uint16_t sleepInterval[uniqueCount(UQ_BLAZE_RADIO)];
  
  /** The current radio we're working with, or NO_RADIO */
  uint8_t currentRadio;
  
  /** TRUE if we just received a message (?) */
  bool received;
  
  /** Current message being sent */
  message_t *currentMsg;
  
  /** Current message length to send */
  uint8_t currentLen;
  
  /** TRUE if this module is sending a message */
  bool sending;
  
  
  /**
   * Radio Power, Check State, and Duty Cycling State
   */
  enum {
    S_OFF, // off by default
    S_TURNING_ON,
    S_ON,
    S_TURNING_OFF,
  };
  
  enum {
    NO_RADIO = 0xFF,
  };
  
  /***************** Prototypes ****************/
  void startOffTimer();
  
  bool finishSplitControlRequests();
  bool isDutyCycling();

  void receiveCheck();

  void beginStart();
  void beginStop();  
  void startDone();
  void stopDone();
  
  
  /***************** Init Commands *****************/ 
  command error_t Init.init() {
    int i;
    for(i = 0; i < uniqueCount(UQ_BLAZE_RADIO); i++) {
      sleepInterval[i] = 0;
    }
    
    call SplitControlState.forceState(S_OFF);
    currentRadio = NO_RADIO;
    received = FALSE;
    sending = FALSE;
    return SUCCESS;
  }
  
  /***************** PowerCycle Commands ****************/
  /**
   * Set the sleep interval, in binary milliseconds
   * @param sleepIntervalMs the sleep interval in [ms]
   */
  command void PowerCycle.setSleepInterval[radio_id_t radioId](uint16_t sleepIntervalMs) {
    
    if(call SplitControlState.isState(S_ON) && currentRadio == radioId) {
      if(!sleepInterval[radioId] && sleepIntervalMs) {
        // We were always on, now lets duty cycle
        beginStop();
      }
      
      sleepInterval[radioId] = sleepIntervalMs;
      
      if(sleepInterval[radioId] == 0 && call SplitControlState.isState(S_ON)) {
        /*
         * Leave the radio on permanently if sleepInterval == 0 and the radio is 
         * supposed to be enabled
         */
        if(call RadioPowerState.getState() == S_OFF) {  
          beginStart();
        }
      }
    
    } else {
      sleepInterval[radioId] = sleepIntervalMs;
    }
  }
  
  /**
   * @return the sleep interval in [ms]
   */
  command uint16_t PowerCycle.getSleepInterval[radio_id_t radioId]() {
    return sleepInterval[radioId];
  }
  
  
  /***************** SplitControl Commands ****************/
  command error_t SplitControl.start[radio_id_t radioId]() {
    if(call SplitControlState.isState(S_ON)) {
      return EALREADY;
      
    } else if(call SplitControlState.isState(S_TURNING_ON)) {
      return SUCCESS;
    
    } else if(!call SplitControlState.isState(S_OFF)) {
      return EBUSY;
    }
    
    currentRadio = radioId;
    
    // Radio was off, now has been told to turn on or duty cycle.
    call SplitControlState.forceState(S_TURNING_ON);
    
    beginStart();
    
    return SUCCESS;
  }
  
  command error_t SplitControl.stop[radio_id_t radioId]() {
    if(call SplitControlState.isState(S_OFF)) {
      return EALREADY;
      
    } else if(call SplitControlState.isState(S_TURNING_OFF)) {
      return SUCCESS;
    
    } else if(!call SplitControlState.isState(S_ON)) {
      return EBUSY;
    }
    
    call SplitControlState.forceState(S_TURNING_OFF);
    
    beginStop();
    return SUCCESS;
  }
  
  /***************** Send Commands ****************/
  /**
   * Each call to this send command gives the message a single
   * DSN that does not change for every copy of the message
   * sent out.  For messages that are not acknowledged, such as
   * a broadcast address message, the receiving end does not
   * signal receive() more than once for that message.
   */
  command error_t Send.send[radio_id_t radioId](message_t *msg, uint8_t len) {
    if(sending) {
      return FAIL;
    }
    sending = TRUE;
    
    //(tunit)//assertFail("Send.send()");
    currentMsg = msg;
    currentLen = len;
    
    beginStart();
    
    return SUCCESS;
  }
  
  command error_t Send.cancel[radio_id_t radioId](message_t *msg) {
    return call SubSend.cancel[radioId](msg);
  }
  
  command uint8_t Send.maxPayloadLength[radio_id_t radioId]() {
    return call SubSend.maxPayloadLength[radioId]();
  }

  command void *Send.getPayload[radio_id_t radioId](message_t* msg, uint8_t len) {
    return call SubSend.getPayload[radioId](msg, len);
  }
  
  /***************** SubSend Events ****************/
  event void SubSend.sendDone[radio_id_t radioId](message_t *msg, error_t error) {
    //(tunit)//assertFail("SubSend.sendDone");
    startOffTimer();
    sending = FALSE;
    signal Send.sendDone[radioId](msg, error);
  } 
  
  /***************** SubReceive Events ****************/
  event message_t *SubReceive.receive[radio_id_t radioId](message_t *msg, void *payload, uint8_t len) {
    if(isDutyCycling()) {
      if(!call RadioPowerState.isState(S_ON)) {
        beginStart();
      }
    
      startOffTimer();
    }
    
    return signal Receive.receive[radioId](msg, payload, len);
  }
  
  /***************** Timer Events ****************/
  event void OnTimer.fired() {
    if(isDutyCycling()) {
      if(call RadioPowerState.getState() == S_OFF && call SendState.isIdle()) {
        //(tunit)//assertFail("OnTimer: start");
        beginStart();
        received = FALSE;
        
      } else {
        // Someone else turned on the radio, try again in awhile
        call OnTimer.startOneShot(sleepInterval[currentRadio]);
      }
    }
  }
  
  /**
   * We are done with the short delay following any activity. Perform
   * another receive check, and if the channel is free, go back to sleep.
   */
  event void OffTimer.fired() {
    if(call SplitControlState.isState(S_ON) && isDutyCycling()) {
      
      if(call SendState.isIdle()) {
        if(!received) {
          //(tunit)//assertFail("OffTimer: stop");
          beginStop();
          return;
        } 
      }
      
      startOffTimer();
    }
  }
  
  /***************** SubControl Events ****************/
  event void SubControl.startDone[radio_id_t radioId](error_t error) {
    startDone();
  }
  
  event void SubControl.stopDone[radio_id_t radioId](error_t error) {
    stopDone();
  }
  
  /***************** RxInterrupt Events ****************/
  async event void RxInterrupt.fired[radio_id_t radioId]() {
    // TODO should we go to sleep if packets are transmitting for other nodes?
    atomic received = TRUE;
  }
  
  /***************** Tasks ****************/
  
  /***************** Functions ****************/
  /**
   * Start the off timer, leaving the radio on for a short period of time
   * before doing another receive check and possibly going back to sleep.
   */
  void startOffTimer() {
    if(isDutyCycling()) {
      received = FALSE;
      call OffTimer.startOneShot(DELAY_AFTER_ACTIVITY);
    }
  }
  
  /**
   * @return TRUE if the radio should be actively duty cycling
   */
  bool isDutyCycling() {
    return sleepInterval[currentRadio] > 0 && call SplitControlState.isState(S_ON);
  }
  
  
  /**
   * @return TRUE if we successfully handled a SplitControl request
   */
  bool finishSplitControlRequests() {
    radio_id_t radio = currentRadio;
    
    if(call SplitControlState.isState(S_TURNING_OFF)) {
      if(!call RadioPowerState.isState(S_OFF)) {
        beginStop();
        return TRUE;
      }
      
      //(tunit)//assertFail("Sig SC.stopDone()");
      call SplitControlState.forceState(S_OFF);
      currentRadio = NO_RADIO;
      signal SplitControl.stopDone[radio](SUCCESS);
      return TRUE;
      
    } else if(call SplitControlState.isState(S_TURNING_ON)) {
      if(!call RadioPowerState.isState(S_ON)) {
        beginStart();
        return TRUE;
      }
      
      //(tunit)//assertFail("Sig SC.startDone()");
      // Starting while we're duty cycling first turns off the radio
      call SplitControlState.forceState(S_ON);
      signal SplitControl.startDone[radio](SUCCESS);
      return TRUE;
    }
    
    return FALSE;
  }
  
  /**
   * Entry point for starting the radio
   */
  void beginStart() {
    error_t error;
      
    //(tunit)//assertFail("beginStart()");
    error = call SubControl.start[currentRadio]();
    
    if(error == EALREADY) {
      //(tunit)//assertFail("Already on");
      startDone();
    }
  }
  
  /** 
   * Entry point for stopping the radio
   */
  void beginStop() {
    error_t error;
    
    //(tunit)//assertFail("beginStop()");
     
    if(!call SendState.isIdle()) {
      // Don't turn the radio off
      return;
    }
    
    error = call SubControl.stop[currentRadio]();
    if(error == EALREADY) {
      //(tunit)//assertFail("Already off");
      stopDone(); 
    }
  }
  
  /**
   * The radio started
   */
  void startDone() {
    error_t error;
    //(tunit)//assertFail("startDone()");
    call RadioPowerState.forceState(S_ON);
    
#if BLAZE_ENABLE_LPL_LEDS
    call Leds.led3On();
#endif


    
    finishSplitControlRequests();
    
    if(isDutyCycling() && call SendState.isIdle()) {
      receiveCheck();
    }
    
    if(sending) {
      //(tunit)//assertFail("Sending..");
      error = call SubSend.send[currentRadio](currentMsg, currentLen);
      if(error != SUCCESS) {
        //(tunit)//assertFail("Send imm. fail");  
        startOffTimer();
        sending = FALSE;
        signal Send.sendDone[currentRadio](currentMsg, error);
      }
    }
  }
  
  /**
   * The radio stopped
   */
  void stopDone() {
    call RadioPowerState.forceState(S_OFF);
    
#if BLAZE_ENABLE_LPL_LEDS
    call Leds.led3Off();
#endif


    
    //(tunit)//assertFail("stopDone()");
    
    if(finishSplitControlRequests()) {
      // Don't duty cycle anymore.
      return;
      
    } else if(!call SendState.isIdle()) {
      // Not sure if or why we turn off intermittently when we're sending, but 
      // make sure CSMA exits properly and turn that radio back on.
      call SubSend.cancel[currentRadio](currentMsg);
      beginStart();
      
    } else if(isDutyCycling()) {
      call OnTimer.startOneShot(sleepInterval[currentRadio]);
    }
  }
  
  
  /**
   * Attempt to perform a receive check.
   * The receive checks here are really stupid: we just leave the radio on
   * for a short period of time and try to receive a packet.
   */
  void receiveCheck() {
    //(tunit)//assertFail("RX Check");
    received = FALSE;
    call OffTimer.startOneShot(RECEIVE_CHECK_DURATION);
  }

  
  
  /**************** Defaults ****************/  
  default event void SplitControl.startDone[radio_id_t radioId](error_t error) {
  }
  
  default event void SplitControl.stopDone[radio_id_t radioId](error_t error) {
  }
  
  default event message_t *Receive.receive[radio_id_t radioId](message_t *msg, void *payload, uint8_t len) {
    return msg;
  }
  
  default event void Send.sendDone[radio_id_t radioId](message_t *msg, error_t error) {
  }
  
  default async command error_t RxInterrupt.enableRisingEdge[radio_id_t id]() {
    return FAIL;
  }
  
  default async command error_t RxInterrupt.enableFallingEdge[radio_id_t id]() {
    return FAIL;
  }
  
  default async command error_t RxInterrupt.disable[radio_id_t id]() {
    return FAIL;
  }
  
}


