

configuration TestCancelC {
}

implementation {
  components new TestCaseC() as TestCancelAtCongestionBackoffC;
  
  
  components CC2420TransmitC,
      CC2420ActiveMessageC,
      CC2420PacketC,
      TestCancelP;
      
  TestCancelP.RadioBackoff -> CC2420TransmitC;
  TestCancelP.CC2420Transmit -> CC2420TransmitC;
  TestCancelP.CC2420PacketBody -> CC2420PacketC;
  TestCancelP.SplitControl -> CC2420ActiveMessageC;

  TestCancelP.SetUpOneTime -> TestCancelAtCongestionBackoffC.SetUpOneTime;
  TestCancelP.TearDownOneTime -> TestCancelAtCongestionBackoffC.TearDownOneTime;
  
  TestCancelP.TestCancelAtCongestionBackoff -> TestCancelAtCongestionBackoffC;
}

