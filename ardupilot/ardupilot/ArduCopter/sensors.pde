// -*- tab-width: 4; Mode: C++; c-basic-offset: 4; indent-tabs-mode: nil -*-

static void init_barometer(bool full_calibration)
{
    gcs_send_text_P(SEVERITY_LOW, PSTR("Calibrating barometer"));
    if (full_calibration) {
        barometer.calibrate();
    }else{
        barometer.update_calibration();
    }
    gcs_send_text_P(SEVERITY_LOW, PSTR("barometer calibration complete"));
}

// return barometric altitude in centimeters
static void read_barometer(void)
{
    barometer.update();
    if (should_log(MASK_LOG_IMU)) {
        Log_Write_Baro();
    }
    baro_alt = barometer.get_altitude() * 100.0f;
    baro_climbrate = barometer.get_climb_rate() * 100.0f;

    motors.set_air_density_ratio(barometer.get_air_density_ratio());
}

#if CONFIG_SONAR == ENABLED
static void init_sonar(void)
{
   sonar.init();
}
#endif

// return sonar altitude in centimeters
static int16_t read_sonar(void)
{
#if CONFIG_SONAR == ENABLED
    sonar.update();

    // exit immediately if sonar is disabled
    if (!sonar_enabled || (sonar.status() != RangeFinder::RangeFinder_Good)) {
        sonar_alt_health = 0;
        return 0;
    }

    int16_t temp_alt = sonar.distance_cm();

    if (temp_alt >= sonar.min_distance_cm() && 
        temp_alt <= sonar.max_distance_cm() * SONAR_RELIABLE_DISTANCE_PCT) {
        if ( sonar_alt_health < SONAR_ALT_HEALTH_MAX ) {
            sonar_alt_health++;
        }
    }else{
        sonar_alt_health = 0;
    }

 #if SONAR_TILT_CORRECTION == 1
    // correct alt for angle of the sonar
    float temp = ahrs.cos_pitch() * ahrs.cos_roll();
    temp = max(temp, 0.707f);
    temp_alt = (float)temp_alt * temp;
 #endif

    return temp_alt;
#else
    return 0;
#endif
}

// initialise compass
static void init_compass()
{
    if (!compass.init() || !compass.read()) {
        // make sure we don't pass a broken compass to DCM
        cliSerial->println_P(PSTR("COMPASS INIT ERROR"));
        Log_Write_Error(ERROR_SUBSYSTEM_COMPASS,ERROR_CODE_FAILED_TO_INITIALISE);
        return;
    }
    ahrs.set_compass(&compass);
}

// initialise optical flow sensor
static void init_optflow()
{
#if OPTFLOW == ENABLED
    // exit immediately if not enabled
    if (!optflow.enabled()) {
        return;
    }

    // initialise optical flow sensor
    optflow.init();
#endif      // OPTFLOW == ENABLED
}

// called at 200hz
#if OPTFLOW == ENABLED
static void update_optical_flow(void)
{
    static uint32_t last_of_update = 0;

    // exit immediately if not enabled
    if (!optflow.enabled()) {
        return;
    }

    // read from sensor
    optflow.update();

    // write to log and send to EKF if new data has arrived
    if (optflow.last_update() != last_of_update) {
        last_of_update = optflow.last_update();
        uint8_t flowQuality = optflow.quality();
        Vector2f flowRate = optflow.flowRate();
        Vector2f bodyRate = optflow.bodyRate();
        ahrs.writeOptFlowMeas(flowQuality, flowRate, bodyRate, last_of_update);
        if (g.log_bitmask & MASK_LOG_OPTFLOW) {
            Log_Write_Optflow();
        }
    }
}
#endif  // OPTFLOW == ENABLED

// read_battery - check battery voltage and current and invoke failsafe if necessary
// called at 10hz
static void read_battery(void)
{
    battery.read();

    // update compass with current value
    if (battery.has_current()) {
        compass.set_current(battery.current_amps());
    }

    // update motors with voltage and current
    if (battery.get_type() != AP_BattMonitor::BattMonitor_TYPE_NONE) {
        motors.set_voltage(battery.voltage());
    }
    if (battery.has_current()) {
        motors.set_current(battery.current_amps());
    }

    // calculate energy required in mAh to perform an RTL from vehicle's current position
    float fs_dist_ofs = 0.0f;  // units in mAh
    if (g.fs_batt_curr_rtl != 0.0f && ap.home_state != HOME_UNSET && position_ok()) {
        // calculate mAh required to:
        // 1. rise to RTL_ALT at WPNAV_SPEED_UP (cm/s) (if necessary)
        // 2. fly home at RTL_SPEED (cm/s)
        // 3. descend from RTL_ALT or current altitude at WPNAV_SPEED_DN (cm/s).
        // Conversions: 1000 milliamps per amp & 3600 seconds per hour
        // home_distance is in cm
        // fs_batt_curr_rtl is in amps
        // rtl_altitude is in cm

        float current_alt_cm = inertial_nav.get_altitude();

        float current_rtl_alt_cm = max(current_alt_cm + max(0, g.rtl_climb_min), max(g.rtl_altitude, RTL_ALT_MIN));

        // calculate mAh required to rise
        float fs_rise_ofs = (current_rtl_alt_cm - current_alt_cm) * (g.fs_batt_curr_rtl*1000.0f) / (3600*wp_nav.get_speed_up());

        // calculate mAh required to fly home
        float fs_home_ofs = (home_distance) * (g.fs_batt_curr_rtl*1000.0f) / (3600*g.rtl_speed_cms);

        // calculate mAh required to descend to LAND_START_ALT
        float fs_land_init_ofs = (current_rtl_alt_cm - LAND_START_ALT) * (g.fs_batt_curr_rtl*1000.0f) / (3600*wp_nav.get_speed_down());

        // calculate mAh required to descend from LAND_START_ALT to ground
        float fs_land_final_ofs = LAND_START_ALT * (g.fs_batt_curr_rtl*1000.0f) / (3600*g.land_speed);

        // sum up required mAh fs
        fs_dist_ofs = fs_rise_ofs + fs_home_ofs + fs_land_init_ofs + fs_land_final_ofs;

        // log offsets
        Log_Write_Failsafe(fs_dist_ofs, fs_rise_ofs, fs_home_ofs, fs_land_init_ofs, fs_land_final_ofs);
    }

    // check for low voltage or current if the low voltage check hasn't already been triggered
    // we only check when we're not powered by USB to avoid false alarms during bench tests
    if (!ap.usb_connected && !failsafe.battery && battery.exhausted(g.fs_batt_voltage, g.fs_batt_mah + fabsf(fs_dist_ofs))) {
        failsafe_battery_event();
    }

    // log battery info to the dataflash
    if (should_log(MASK_LOG_CURRENT)) {
        Log_Write_Current();
    }
}

// read the receiver RSSI as an 8 bit number for MAVLink
// RC_CHANNELS_SCALED message
void read_receiver_rssi(void)
{
    // avoid divide by zero
    if (g.rssi_range <= 0) {
        receiver_rssi = 0;
    }else{
        rssi_analog_source->set_pin(g.rssi_pin);
        float ret = rssi_analog_source->voltage_average() * 255 / g.rssi_range;
        receiver_rssi = constrain_int16(ret, 0, 255);
    }
}

#if EPM_ENABLED == ENABLED
// epm update - moves epm pwm output back to neutral after grab or release is completed
void epm_update()
{
    epm.update();
}
#endif
