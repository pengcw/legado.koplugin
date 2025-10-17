local Blitbuffer = require("ffi/blitbuffer")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local Size = require("ui/size")
local UIManager = require("ui/uimanager")
local FocusManager = require("ui/widget/focusmanager")
local CenterContainer = require("ui/widget/container/centercontainer")
local FrameContainer = require("ui/widget/container/framecontainer")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local OverlapGroup = require("ui/widget/overlapgroup")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local LeftContainer = require("ui/widget/container/leftcontainer")
local RenderImage = require("ui/renderimage")
local LineWidget = require("ui/widget/linewidget")
local ScrollTextWidget = require("ui/widget/scrolltextwidget")
local ImageWidget = require("ui/widget/imagewidget")
local TitleBar = require("ui/widget/titlebar")
local TextWidget = require("ui/widget/textwidget")
local logger = require("logger")

local ButtonTable = require("ui/widget/buttontable")
local util = require("util")
local Device = require("device")
local Backend = require("Legado/Backend")

local Screen = Device.screen

local Constants = {
    COVER_WIDTH_RATIO_PORTRAIT = 0.4, -- 竖屏封面宽度比例
    COVER_WIDTH_RATIO_LANDSCAPE = 0.3, -- 横屏封面宽度比例
    COVER_MAX_HEIGHT_RATIO = 1/3, -- 封面最大高度比例
    METADATA_TOP_PADDING_RATIO = 0.15, -- 元数据顶部填充比例
    METADATA_HORIZONTAL_SPACING_RATIO = 0.02, -- 元数据水平间距比例
    DETAILS_HORIZONTAL_PADDING_RATIO = 0.05, -- 详情页水平填充比例
    DESCRIPTION_HEIGHT_RATIO = 5 / 15, -- 描述高度比例
    BUTTON_GROUP_SHRINK_MIN_WIDTH_RATIO = 0.5, -- 按钮组最小宽度比例
    COVER_IMAGE_MARGIN = 5, -- 封面边距
    COVER_IMAGE_PADDING = 10, -- 封面填充
    COVER_IMAGE_BORDER_SIZE = 1, -- 封面边框
    PLACEHOLDER_COVER = "resources/koreader.png",
}

local BookDetails = FocusManager:extend{
    padding = Size.padding.fullscreen,
    bookinfo = nil,
    callbacks = nil,
    has_reload_btn = nil,
}

function BookDetails:init()
    if type(self.bookinfo) ~= "table" then return end

    -- The book id may not be generated yet
    if not self.bookinfo.cache_id then
        self.bookinfo.name = util.trim(self.bookinfo.name)
        self.bookinfo.author = util.trim(self.bookinfo.author or "")
        if self.bookinfo.author == "" then
            self.bookinfo.author = '未知'
        end
        local show_book_title = ("%s (%s)"):format(self.bookinfo.name, self.bookinfo.author)
        local md5 = require("ffi/sha2").md5
        self.bookinfo.cache_id = tostring(md5(show_book_title))
    end

    self.layout = {}
    self.small_font = Font:getFace("smallffont")
    self.medium_font = Font:getFace("ffont")
    self.large_font = Font:getFace("largeffont")
    -- "portrait" - 竖屏模式 "landscape" - 横屏模式
    self.screen_mode = Screen:getScreenMode()
    self.screen_size = Screen:getSize()

    self.covers_fullscreen = true
    self[1] = FrameContainer:new{
        dimen = Geom:new{
            w = self.screen_size.w,
            h = self.screen_size.h,
        },
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 0,
        padding = 0,
        self:getDetailsContent(self.screen_size.w)
    }

    if Device:hasKeys() then
        if Device.Input and Device.Input.group and Device.Input.group.Back then
            self.key_events.Close = { { Device.Input.group.Back } }
        end
        if Device:hasFewKeys() then
            self.key_events.Close = { { "Left" } }
        end
    end
end

function BookDetails:getDetailsContent(width)
    local title_bar = TitleBar:new{
        width = width,
        bottom_v_padding = 0,
        close_callback = function() self:onClose() end,
        show_parent = self,
    }

    local book_details = self:getBookDetails()
    local header = self:getHeader("简介")
    local description = self:getDescriptionContent()

    -- Calculate the height of all elements except the button group
    local other_elements_height = title_bar:getSize().h +
                                  book_details:getSize().h +
                                  header:getSize().h +
                                  description:getSize().h

    local button_group = self:getButtonGroup(other_elements_height)

    local content = VerticalGroup:new{
        align = "left",
        title_bar,
        book_details,
        header,
        description,
        button_group,
    }
    return content
end

function BookDetails:getButtonGroup(other_elements_height)
    local buttons = {}
    if type(self.callbacks) == "table" then
        for text, callback in pairs(self.callbacks) do
            table.insert(buttons, {
                text = text,
                callback = function()
                    callback(self.bookinfo)
                    self:onClose()
                end
            })
        end
    end
    if self.has_reload_btn then
        table.insert(buttons, {
            text = "封面刷新",
            callback = function()
                local image_path = Backend:get_default_cover_cache(self.bookinfo.cache_id)  
                if type(image_path) == "string" and util.fileExists(image_path) then
                    pcall(util.removeFile, image_path)
                    UIManager:nextTick(function()
                        if not util.fileExists(image_path) then self:_reload() end
                    end)
                end
            end,
        })
    end
    table.insert(buttons, {
        text = "返回",
        callback = function()
            self:onClose()
        end,
    })

    -- Create vertical button layout first to check height
    local vertical_buttons = {}
    for _, btn in ipairs(buttons) do
        table.insert(vertical_buttons, {btn})
    end

    local button_table = ButtonTable:new {
        buttons = vertical_buttons,
        show_parent = self,
        shrink_unneeded_width = true,
        shrink_min_width = self.screen_size.w * Constants.BUTTON_GROUP_SHRINK_MIN_WIDTH_RATIO,
    }

    -- Calculate remaining height
    local remaining_height = self.screen_size.h - other_elements_height

    -- If too tall, switch to horizontal layout
    if button_table:getSize().h > remaining_height then
        button_table = ButtonTable:new {
            width = self.screen_size.w,
            buttons = {buttons}, -- Single row for horizontal layout
            show_parent = self,
        }
    end
    
    return CenterContainer:new{
        dimen = Geom:new{ w = self.screen_size.w, h = remaining_height },
        FrameContainer:new{
            bordersize = Constants.COVER_IMAGE_BORDER_SIZE,
            margin = 0,
            padding = 0,
            button_table,
        }
    }
end

function BookDetails:_createCoverImage(image_path, max_width, max_height, min_frame_height)
    min_frame_height = min_frame_height or 0

    local function safe_render_image(path)
        local ok, img = pcall(RenderImage.renderImageFile, RenderImage, path, false)
        if ok and img and type(img.getWidth) == "function" then
            local w, h = img:getWidth(), img:getHeight()
            if w > 0 and h > 0 then
                return img, w, h
            end
        end
        return nil
    end

    local image, actual_w, actual_h = safe_render_image(image_path)
    if not image then
        -- Do not delete placeholder image
        if image_path ~= Constants.PLACEHOLDER_COVER then
            -- pcall(util.removeFile, image_path)
            image, actual_w, actual_h = safe_render_image(Constants.PLACEHOLDER_COVER)
        end
        if not image then
            actual_w, actual_h = max_width, max_height
        end
    end


    local container_w = max_width - (Constants.COVER_IMAGE_PADDING * 2)
    local container_h = max_height - (Constants.COVER_IMAGE_PADDING * 2)
    local scale_w = container_w / actual_w
    local scale_h = container_h / actual_h
    local scale = math.min(scale_w, scale_h)

    local scaled_w = math.floor(actual_w * scale)
    local scaled_h = math.floor(actual_h * scale)

    local image_widget = ImageWidget:new{
        image = image,
        width = scaled_w,
        height = scaled_h,
        scale_factor = 0,
        alpha = true,
    }

    -- The final container height must be at least min_frame_height.
    -- The container's height is determined by its child (CenterContainer) + padding, margin, and border.
    -- So, we need to calculate the required height for the CenterContainer.
    local non_content_h = (Constants.COVER_IMAGE_PADDING * 2) + (Constants.COVER_IMAGE_MARGIN * 2) + (Constants.COVER_IMAGE_BORDER_SIZE * 2)
    local min_center_container_h = min_frame_height - non_content_h
    local center_container_h = math.max(scaled_h, min_center_container_h)

    return FrameContainer:new{
        bordersize = Constants.COVER_IMAGE_BORDER_SIZE,
        margin = Constants.COVER_IMAGE_MARGIN,
        padding = Constants.COVER_IMAGE_PADDING,
        CenterContainer:new{
            dimen = Geom:new{
                w = container_w, -- Use full available width to center the image
                h = center_container_h,
            },
            image_widget
        }
    }, image_widget
end

function BookDetails:_createMetadataGroup(metadata_table)
    local metadata_label_group = VerticalGroup:new{
        align = "left",
    }
    local metadata_labeled_group = VerticalGroup:new{
        align = "left",
    }

    for _, item in ipairs(metadata_table) do
        table.insert(metadata_label_group, TextWidget:new{
            text = item.label,
            face = self.small_font,
            fgcolor = Blitbuffer.COLOR_GRAY_9,
        })
        table.insert(metadata_labeled_group, TextWidget:new{
            text = item.value or "N/A",
            face = self.small_font,
        })
    end

    return HorizontalGroup:new{
        align = "top",
        metadata_label_group,
        HorizontalSpan:new{ width = math.floor(self.screen_size.w * Constants.METADATA_HORIZONTAL_SPACING_RATIO)},
        metadata_labeled_group,
    }
end

function BookDetails:getBookDetails()
    local screen_width = self.screen_size.w
    local screen_height = self.screen_size.h

    local img_width_ratio = self.screen_mode == "landscape" and Constants.COVER_WIDTH_RATIO_LANDSCAPE or Constants.COVER_WIDTH_RATIO_PORTRAIT
    local img_width = screen_width * img_width_ratio
    local img_max_height = screen_height * Constants.COVER_MAX_HEIGHT_RATIO

    -- Create metadata group
    local book_author_string = self.bookinfo.author or "Unknown Author"
    local book_metadata_group = VerticalGroup:new{
        align = "left",
        VerticalSpan:new{ width = img_max_height * Constants.METADATA_TOP_PADDING_RATIO},
        TextWidget:new{
            text = self.bookinfo.name or "Unknown Title",
            face = self.large_font,
        },
        TextWidget:new{
            text = "by " .. book_author_string,
            face = self.medium_font,
        }
    }
    local metadata_table = {
        { label = "分类", value = self.bookinfo.kind },
        { label = "来源", value = self.bookinfo.originName },
        { label = "总章数", value = self.bookinfo.totalChapterNum },
        { label = "总字数", value = self.bookinfo.wordCount },
    }
    table.insert(book_metadata_group, self:_createMetadataGroup(metadata_table))

    -- Ensure cover image is at least as tall as the metadata
    local metadata_height = book_metadata_group:getSize().h
    img_max_height = math.max(img_max_height, metadata_height)
    
    local image_path = Backend:get_default_cover_cache(self.bookinfo.cache_id)
    local final_cover_component
    
    if not( type(image_path) == "string" and util.fileExists(image_path) ) then
        
        local book_cache_id = self.bookinfo.cache_id
        local cover_url = self.bookinfo.coverUrl

        -- Create placeholder image container
        local placeholder_container, _ = self:_createCoverImage(Constants.PLACEHOLDER_COVER, img_width, img_max_height, metadata_height)

        self.loading_text_widget = TextWidget:new{
            text = "正在加载",
            face = self.medium_font,
            fgcolor = Blitbuffer.COLOR_GRAY_9
        }

        -- Combine placeholder and text widget
        local cover_group = OverlapGroup:new{
                    placeholder_container,
                    CenterContainer:new{
                        dimen = Geom:new{
                            w = placeholder_container:getSize().w,
                            h = placeholder_container:getSize().h,
                        },
                        self.loading_text_widget,
                    }
            }
        
        final_cover_component = cover_group

        Backend:launchProcess(function()
            return Backend:download_cover_img(book_cache_id, cover_url)
        end, function(status, cover_path, cover_name)
            if self.loading_text_widget then
                if status == true and type(cover_path) == "string" and util.fileExists(cover_path) then
                   self:reloadCoverImage()
                else
                    self.loading_text_widget:setText("加载失败")
                    UIManager:setDirty("all", "partial")
                    UIManager:forceRePaint()
                end
            end
        end)
        
    else
        local cover_image_container, cover_image_widget = self:_createCoverImage(image_path, img_width, img_max_height, metadata_height)
        self.cover_image_widget = cover_image_widget
        final_cover_component = cover_image_container
    end

    local book_details_group = HorizontalGroup:new{
        align = "center",
        HorizontalSpan:new{ width = math.floor(screen_width * Constants.DETAILS_HORIZONTAL_PADDING_RATIO) }
    }
    if final_cover_component then
        table.insert(book_details_group, final_cover_component)
    end
    table.insert(book_details_group, HorizontalSpan:new{ width = math.floor(screen_width * Constants.DETAILS_HORIZONTAL_PADDING_RATIO) })
    table.insert(book_details_group, book_metadata_group)

    return book_details_group
end

function BookDetails:getHeader(title)
    local width, height = self.screen_size.w, Size.item.height_default

    local header_title = TextWidget:new{
        text = title,
        face = self.medium_font,
        fgcolor = Blitbuffer.COLOR_GRAY_9
    }
    local padding_span = HorizontalSpan:new{ width = self.padding }
    local line_width = (width - header_title:getSize().w) / 2 - self.padding * 2
    line_width = math.max(0, line_width) -- ensure line_width is not negative
    local line_container = LeftContainer:new{
        dimen = Geom:new{ w = line_width, h = height },
        LineWidget:new{
            background = Blitbuffer.COLOR_LIGHT_GRAY,
            dimen = Geom:new{
                w = line_width,
                h = Size.line.thick,
            }
        }
    }

    local span_top, span_bottom
    if self.screen_mode == "landscape" then
        span_top = VerticalSpan:new{ width = Size.span.horizontal_default }
        span_bottom = VerticalSpan:new{ width = Size.span.horizontal_default }
    else
        span_top = VerticalSpan:new{ width = Size.item.height_default }
        span_bottom = VerticalSpan:new{ width = Size.span.vertical_large }
    end

    return VerticalGroup:new{
        span_top,
        HorizontalGroup:new{
            align = "center",
            padding_span,
            line_container,
            padding_span,
            header_title,
            padding_span,
            line_container,
            padding_span,
        },
        span_bottom,
    }
end

function BookDetails:getDescriptionContent()
    local screen_width = self.screen_size.w
    local screen_height = self.screen_size.h
    
    local text = ScrollTextWidget:new{
        text = self:decodeHtmlEntities(self.bookinfo.intro or ""),
        --face = self.medium_font,
        face = Font:getFace("infont"),
        width = screen_width - self.padding * 2,
        height = screen_height * Constants.DESCRIPTION_HEIGHT_RATIO,
        dialog = self,
    }

    return CenterContainer:new{
        dimen = Geom:new{ w = screen_width, h = text:getSize().h },
        text
    }
end

function BookDetails:reloadCoverImage()
    local image_path = Backend:get_default_cover_cache(self.bookinfo.cache_id)
    if type(image_path) == "string" and util.fileExists(image_path) then
        self:_reload()
    end
end

function BookDetails:decodeHtmlEntities(text)
    return util.htmlEntitiesToUtf8(text)
end

function BookDetails:_reload()
    self[1][1] = self:getDetailsContent(self.screen_size.w)
    UIManager:setDirty("all", "partial")
    UIManager:forceRePaint()
end

function BookDetails:onShow()
    UIManager:setDirty(self, function()
        return "ui", self[1].dimen
    end)
end

function BookDetails:onCloseWidget()
    if self.cover_image_widget and self.cover_image_widget.free then
        self.cover_image_widget:free()
    end
    UIManager:setDirty(nil, function()
        return "ui", self[1].dimen
    end)
end

function BookDetails:onClose()
    UIManager:close(self)
    return true
end

return BookDetails
