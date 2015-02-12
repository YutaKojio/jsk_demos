#!/usr/bin/env roseus

(ros::roseus "ocs_executive")
(ros::roseus-add-srvs "std_srvs")
(ros::roseus-add-msgs "image_view2")
(ros::roseus-add-msgs "geometry_msgs")
(ros::roseus-add-srvs "topic_tools")
(ros::roseus-add-msgs "drc_com_common")
(ros::roseus-add-msgs "jsk_recognition_msgs")
(ros::roseus-add-msgs "jsk_interactive_marker")
(ros::load-ros-manifest "drc_task_common")
(load "package://drc_task_common/euslisp/util.l")
(load "package://drc_task_common/euslisp/state-machine.l")
;; state
;;  :initial -> ...
;;  :go-pos-region-select -> :wait-for-exec-or-cancel [rectangle-callback]
;;  :wait-for-exec-or-cancel -> :initial [:exec-callback or :cancel-callback]

(defclass ocs-executive-app
  :super propertied-object
  :slots (state task rectangle-region go-pos-coords smachine look-at-pos
                fc2ocs-message-handler))

(defmethod ocs-executive-app
  (:init ()
    ;;(setq state :initial)
    (setq fc2ocs-message-handler (instance narrowband-message-handler :init))
    (send fc2ocs-message-handler :register-callbacks
          (list drc_com_common::FC2OCSSmall::*GO_POS_POSE*
                self :go-pos-pose-result-callback)
          (list drc_com_common::FC2OCSSmall::*GO_POS_FINISHED*
                self :go-pos-finished-callback)
          (list drc_com_common::FC2OCSSmall::*LOOK_AT_POS*
                self :look-at-pose-result-callback)
          (list drc_com_common::FC2OCSSmall::*LOOK_AT_FINISHED*
                self :look-at-finished-callback))
    (setq smachine (make-ocs-state-machine))
    (send smachine :register-initial-hook self :initial-callback)
    (send smachine :go-to :initial)     ;force to move to initial state
    self)
  (:fc2ocs-message-handler () fc2ocs-message-handler)
  (:initial-callback ()
    (send self :set-image-view2-mode :none)
    (send self :show-text-on-image "")
    )
  (:set-image-view2-mode (mode)
    (cond 
     ((eq mode :rectangle)
      (call-empty-service "/rqt_image_view2_engine/rectangle_mode"))
     ((eq mode :grabcut-rect)
      (call-empty-service "/rqt_image_view2_engine/grabcut_rect_mode"))
     ((eq mode :line)
      (call-empty-service "/rqt_image_view2_engine/line_mode"))
     ((eq mode :none)
      (call-empty-service "/rqt_image_view2_engine/none_mode"))
     (t
      (error "unknown mode: ~A" mode)
      ))
    )
  (:show-text-on-image (text)
    (let ((msg (instance image_view2::ImageMarker2 :init)))
      (send msg :type image_view2::ImageMarker2::*TEXT*)
      (send msg :position :x 0)
      (send msg :position :y 0.1)
      (send msg :scale 0.02)
      (send msg :filled 2)
      (send msg :left_up_origin t)
      (send msg :ratio_scale t)
      (send msg :text text)
      (ros::publish "/image_marker" msg)
      )
    )
  (:go-pos-button-callback (req)
    (when (send smachine :next? :selecting-region-for-go-pos)
      ;; force to use rectangle mode
      (send self :set-image-view2-mode :rectangle)
      (send self :show-text-on-image "Select rectangle region to go")
      (send smachine :go-to :selecting-region-for-go-pos)
      )
    (send req :response))
  (:look-at-button-callback (req)
    (when (send smachine :next? :selecting-region-for-look-at)
      ;; force to use rectangle mode
      (send self :set-image-view2-mode :rectangle)
      (send self :show-text-on-image "Select rectangle region to look")
      (send smachine :go-to :selecting-region-for-look-at)
      )
    (send req :response))
  (:send-to-fc (msg)
    (ros::publish "/ocs_to_fc_low_speed/input" msg))
  (:rectangle-callback-for-go-pos-region (msg)
    (setq rectangle-region msg)
    ;; send to FC to recognize pos
    (let ((fc-msg (instance drc_com_common::OCS2FCSmall :init)))
      (send fc-msg :type drc_com_common::OCS2FCSmall::*GO_POS_REGION*)
      (send fc-msg :image_roi_info (rect-polygon-stamped-to-integer-vector
                                    msg (length (send fc-msg :image_roi_info))))
      (send self :send-to-fc fc-msg)
      (send smachine :go-to :recognizing-go-pos-goal)))
  (:rectangle-callback-for-look-at-region (msg)
    (setq rectangle-region msg)
    ;; send to FC to recognize pos
    (let ((fc-msg (instance drc_com_common::OCS2FCSmall :init)))
      (send fc-msg :type drc_com_common::OCS2FCSmall::*LOOK_AT_REGION*)
      (send fc-msg :image_roi_info (rect-polygon-stamped-to-integer-vector
                                    msg (length (send fc-msg :image_roi_info))))
      (send self :send-to-fc fc-msg)
      (send smachine :go-to :recognizing-look-at-point)))
  (:rectangle-callback (msg)            ;msg = geometry_msgs/PolygonStamped
    (cond
     ((eq (send smachine :state) :selecting-region-for-go-pos)
      (send self :rectangle-callback-for-go-pos-region msg))
     ((eq (send smachine :state) :selecting-region-for-look-at)
      (send self :rectangle-callback-for-look-at-region msg))
     ))
  (:cancel-button-callback (req)
    (cond
     ((eq (send smachine :state) :selecting-region-for-go-pos)
      (send smachine :go-to :initial))
     ((eq (send smachine :state) :selecting-exec-for-go-pos)
      (send smachine :go-to :initial))
     ((eq (send smachine :state) :selecting-exec-for-look-at)
      (send smachine :go-to :initial))
     )
    ;; clear text message
    (send req :response))
  (:exec-go-pos-button-callback ()
    (let ((msg (instance drc_com_common::OCS2FCSmall :init)))
      (send msg :type drc_com_common::OCS2FCSmall::*GO_POS_EXEC*)
      (send msg :float_params (coords-to-float-vector go-pos-coords))
      (send self :send-to-fc msg)
      (send smachine :go-to :executing-go-pos)))
  (:exec-look-at-button-callback ()
    (let ((msg (instance drc_com_common::OCS2FCSmall :init)))
      (send msg :type drc_com_common::OCS2FCSmall::*LOOK_AT_EXEC*)
      (send msg :float_params (pos-to-float-vector look-at-pos (length (send msg :float_params))))
      (send self :send-to-fc msg)
      (send smachine :go-to :executing-look-at)))
  (:exec-button-callback (req)
    (cond
     ((eq (send smachine :state) :selecting-exec-for-go-pos)
      (send self :exec-go-pos-button-callback)
      )                               ;end of :go-pos
     ((eq (send smachine :state) :selecting-exec-for-look-at)
      (send self :exec-look-at-button-callback)
      )                               ;end of :go-pos
     )
    (send req :response))
  (:look-at-pose-result-callback (msg)
    (when (eq (send smachine :state) :recognizing-look-at-point)
      (let ((params (send msg :params)))
        (send self :show-text-on-image 
              (format nil "look-at ~f ~f ~f" 
                      (* 0.001 (elt params 0))
                      (* 0.001 (elt params 1))
                      (* 0.001 (elt params 2))))
        (setq look-at-pos (float-vector (elt params 0)
                                        (elt params 1)
                                        (elt params 2)))
        (send smachine :go-to :selecting-exec-for-look-at))))
  (:go-pos-pose-result-callback (msg)
    (when (eq (send smachine :state) :recognizing-go-pos-goal)
    (let ((params (send msg :params)))
        ;; show go pos pose in image
        (setq go-pos-coords (make-coords :pos (float-vector (elt params 0)
                                                            (elt params 1)
                                                            (elt params 2))
                                        :rpy (float-vector (elt params 3)
                                                           (elt params 4)
                                                           (elt params 5))))
        (send self :show-text-on-image 
              (format nil "go-pos ~f ~f ~f" 
                      (* 0.001 (elt (send msg :params) 0))
                      (* 0.001 (elt (send msg :params) 1))
                      (rad2deg (elt (send msg :params) 3))
                      ))
        (send smachine :go-to :selecting-exec-for-go-pos))))
  (:go-pos-finished-callback (msg)
    (when (eq (send smachine :state) :executing-go-pos)
      (send smachine :go-to :initial)))
  (:look-at-finished-callback (msg)
    (when (eq (send smachine :state) :executing-look-at)
      (send smachine :go-to :initial)))
  (:go-pos-command-from-rviz-interface (req)
    ;; go to :executing-go-pos from :initial directory
    (when (eq (send smachine :state) :initial)
      (let ((msg (instance drc_com_common::OCS2FCSmall :init)))
        (send msg :type drc_com_common::OCS2FCSmall::*GO_POS_EXEC*)
        (send msg :float_params (coords-to-float-vector (ros::tf-pose->coords (send req :goal))))
        (send self :send-to-fc msg))
      (send smachine :go-to :executing-go-pos))
    (send req :response)
    )
  )

(defun go-pos-callback (req)
  (print 'go-pos-button)
  (send *app* :go-pos-button-callback)
  (send req :response))
(defun exec-callback (req)
  (print 'exec-button)
  (send *app* :exec-callback)
  (send req :response))
(defun cancel-callback (req)
  (print 'cancel-button)
  (send *app* :cancel-callback)
  (send req :response))

(setq *app* (instance ocs-executive-app :init))

;; advertise
(ros::advertise "/image_marker" image_view2::ImageMarker2)
(ros::advertise "/ocs_to_fc_low_speed/input" drc_com_common::OCS2FCSmall)
;; registering services for button UIs
(ros::advertise-service "go_pos" std_srvs::Empty #'send *app* :go-pos-button-callback)
(ros::advertise-service "look_at" std_srvs::Empty #'send *app* :look-at-button-callback)
(ros::advertise-service "exec" std_srvs::Empty #'send *app* :exec-button-callback)
(ros::advertise-service "cancel" std_srvs::Empty #'send *app* :cancel-button-callback)
(ros::advertise-service "go_pos_command_from_rviz_interface" drc_task_common::GoPosCommand #'send *app* :go-pos-command-from-rviz-interface)

;; subscribing image_view2 ROI stuff
(ros::subscribe "/multisense/left/image_rect_color/screenrectangle" geometry_msgs::PolygonStamped
  #'send *app* :rectangle-callback)
(ros::subscribe "/ocs_from_fc_low_speed/output" drc_com_common::FC2OCSSmall
  #'send (send *app* :fc2ocs-message-handler) :root-callback)

(ros::rate 10)
(ros::spin)